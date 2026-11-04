# -*- coding: utf-8 -*-
"""
模型: FPGA 友好 VGG 风格 CNN (config.MODEL_PROFILE 驱动通道配比)

推理分工:
  self.features (Conv3x3+BN+ReLU x N, MaxPool x Blocks) -> FPGA(PA), INT8 权重片上驻留
  self.gap + self.classifier (GAP + FC)                 -> ARM(PU A53), 参数量极小
BN 推理期可无损融合进卷积, 量化交付物一律基于融合后的网络.
"""

import numpy as np
import torch
import torch.nn as nn

import config as C


class MFLCNN(nn.Module):
    def __init__(self, num_classes=C.NUM_CLASSES, profile=None, fc_hidden=C.FC_HIDDEN,
                 convs_per_block=C.CONVS_PER_BLOCK, enable_type_head=None):
        super().__init__()
        self.num_classes = num_classes
        self.profile = list(profile or C.MODEL_PROFILE)
        self.convs_per_block = convs_per_block
        # 可选腐蚀类型双头: 分类头额外输出 [MTL存在, CRC存在] 两个 logit (BCE), FPGA 侧不变
        self.type_head = C.ENABLE_TYPE_HEAD if enable_type_head is None else bool(enable_type_head)
        head_out = num_classes + (2 if self.type_head else 0)

        layers = []
        in_ch = 3
        for out_ch in self.profile:
            for _ in range(convs_per_block):
                layers.append(nn.Conv2d(in_ch, out_ch, kernel_size=3, stride=1, padding=1, bias=False))
                layers.append(nn.BatchNorm2d(out_ch))
                layers.append(nn.ReLU(inplace=True))
                in_ch = out_ch
            layers.append(nn.MaxPool2d(2, 2))
        self.features = nn.Sequential(*layers)      # -> FPGA

        self.gap = nn.AdaptiveAvgPool2d(1)
        self.classifier = nn.Sequential(            # -> ARM
            nn.Flatten(),
            nn.Linear(in_ch, fc_hidden),
            nn.ReLU(inplace=True),
            nn.Linear(fc_hidden, head_out),
        )

    def forward(self, x):
        x = self.gap(self.features(x))
        out = self.classifier(x)
        if self.type_head:
            return out[:, :self.num_classes], out[:, self.num_classes:]
        return out

    def forward_features(self, x):
        return self.features(x)

    def forward_head(self, feat):
        out = self.classifier(self.gap(feat))
        if self.type_head:
            return out[:, :self.num_classes], out[:, self.num_classes:]
        return out


# ---------------------------------------------------------------------------
# 参数统计
# ---------------------------------------------------------------------------
def conv_layers(model):
    """按顺序返回 [(layer_name, Conv2d, BN or None)], 用于量化导出命名"""
    out, i = [], 0
    children = list(model.features.children())
    j = 0
    while j < len(children):
        m = children[j]
        if isinstance(m, nn.Conv2d):
            bn = children[j + 1] if j + 1 < len(children) and isinstance(children[j + 1], nn.BatchNorm2d) else None
            out.append((f"conv{i:02d}", m, bn))
            i += 1
        j += 2 if isinstance(m, nn.Conv2d) else 1
    return out


def layer_table(model, input_hw=(C.INPUT_HEIGHT, C.INPUT_WIDTH)):
    """每层卷积的参数量 / INT8 体积 / 输出特征图尺寸 (FPGA 片上 RAM 预算依据)
    out_hw = 该层卷积运行所在的空间尺寸(MaxPool 在每 block 末尾, 之后尺寸减半)"""
    rows, h, w = [], input_hw[0], input_hw[1]
    for i, (name, conv, bn) in enumerate(conv_layers(model)):
        rows.append({
            "layer": name, "in_ch": conv.in_channels, "out_ch": conv.out_channels,
            "kernel": conv.kernel_size[0], "stride": conv.stride[0],
            "params": int(conv.weight.numel()),
            "int8_kb": round(conv.weight.numel() / 1024, 1),
            "out_hw": [h, w],
        })
        if (i + 1) % model.convs_per_block == 0:   # block 末尾的 MaxPool(2)
            h, w = h // 2, w // 2
    return rows


def count_parameters(model):
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


def model_summary(model):
    rows = layer_table(model)
    conv_params = sum(r["params"] for r in rows)
    fc_params = sum(p.numel() for p in model.classifier.parameters())
    lines = [
        f"模型: {C.model_name()}  输入 3x{C.INPUT_HEIGHT}x{C.INPUT_WIDTH}",
        f"{'层':<8}{'通道':>10}{'输出HxW':>12}{'参数':>10}{'INT8':>9}",
    ]
    for r in rows:
        lines.append(f"{r['layer']:<8}{str(r['in_ch'])+'->'+str(r['out_ch']):>10}"
                     f"{str(r['out_hw'][0])+'x'+str(r['out_hw'][1]):>12}"
                     f"{r['params']:>10,}{r['int8_kb']:>7.1f}K")
    lines += [
        f"卷积权重合计: {conv_params:,} ({conv_params/1024/1024:.2f} MB FP32 / {conv_params/1024:.0f} KB INT8)",
        f"分类头(ARM):  {fc_params:,} ({fc_params/1024:.0f} KB INT8)",
        f"总参数: {count_parameters(model):,}",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# BN 融合
# ---------------------------------------------------------------------------
def fuse_bn_into_convs(model):
    """Conv+BN 融合为带 bias 的 Conv, 返回融合后的副本(结构不变, BN 移除). 推理等价."""
    fused = MFLCNN(num_classes=model.num_classes, profile=model.profile,
                   fc_hidden=model.classifier[1].out_features,
                   convs_per_block=model.convs_per_block,
                   enable_type_head=model.type_head).eval()
    fused.load_state_dict(model.state_dict())   # 占位, 下面逐层覆盖
    new_seq = []
    children = list(model.features.children())
    j = 0
    while j < len(children):
        m = children[j]
        if isinstance(m, nn.Conv2d) and j + 1 < len(children) and isinstance(children[j + 1], nn.BatchNorm2d):
            bn = children[j + 1]
            per_ch = bn.weight.data / torch.sqrt(bn.running_var.data + bn.eps)   # (C,)
            w = m.weight.data * per_ch.view(-1, 1, 1, 1)
            b = bn.bias.data - bn.running_mean.data * per_ch
            nc = nn.Conv2d(m.in_channels, m.out_channels, m.kernel_size, m.stride,
                           m.padding, dilation=m.dilation, groups=m.groups, bias=True)
            nc.weight.data.copy_(w)
            nc.bias.data.copy_(b)
            new_seq.append(nc)
            j += 2
        else:
            new_seq.append(m)
            j += 1
    fused.features = nn.Sequential(*new_seq)
    fused.classifier.load_state_dict(model.classifier.state_dict())
    return fused.eval()


# ---------------------------------------------------------------------------
# 保存 / 加载 / ONNX
# ---------------------------------------------------------------------------
def save_model(model, path, extra=None):
    torch.save({
        "state_dict": model.state_dict(),
        "profile": model.profile,
        "convs_per_block": model.convs_per_block,
        "fc_hidden": model.classifier[1].out_features,
        "num_classes": model.num_classes,
        "type_head": model.type_head,
        **(extra or {}),
    }, path)


def load_model(path, device="cpu"):
    ckpt = torch.load(path, map_location="cpu", weights_only=False)
    model = MFLCNN(num_classes=ckpt.get("num_classes", C.NUM_CLASSES),
                   profile=ckpt.get("profile", C.MODEL_PROFILE),
                   fc_hidden=ckpt.get("fc_hidden", C.FC_HIDDEN),
                   convs_per_block=ckpt.get("convs_per_block", C.CONVS_PER_BLOCK),
                   enable_type_head=ckpt.get("type_head", False))
    model.load_state_dict(ckpt["state_dict"])
    model.to(device).eval()
    return model, ckpt


def export_fp32_onnx(model, path, opset=None):
    """FP32 ONNX 导出(固定输入尺寸, FPGA/ARM 交付基准); 双头时输出 severity+corrosion_type"""
    path = str(path)
    dummy = torch.randn(1, 3, C.INPUT_HEIGHT, C.INPUT_WIDTH)
    out_names = ["severity", "corrosion_type"] if model.type_head else ["output"]
    kwargs = dict(input_names=["input"], output_names=out_names,
                  opset_version=opset or C.ONNX_OPSET, do_constant_folding=True)
    try:
        torch.onnx.export(model.eval(), dummy, path, dynamo=False, **kwargs)
    except TypeError:   # torch 新版本可能已移除 dynamo 参数
        torch.onnx.export(model.eval(), dummy, path, **kwargs)
    try:
        import onnx
        m = onnx.load(path)
        onnx.checker.check_model(m)
        print(f"[ONNX] FP32 导出成功: {path}")
    except ImportError:
        print(f"[ONNX] FP32 导出完成(未装 onnx, 跳过校验): {path}")
    return path


if __name__ == "__main__":
    torch.manual_seed(0)
    net = MFLCNN().eval()
    print(model_summary(net))
    x = torch.randn(2, 3, C.INPUT_HEIGHT, C.INPUT_WIDTH)
    with torch.no_grad():
        y = net(x)
        fused = fuse_bn_into_convs(net)
        y2 = fused(x)

    def _parts(o):
        return list(o) if isinstance(o, (tuple, list)) else [o]

    max_diff = max((a - b).abs().max().item() for a, b in zip(_parts(y), _parts(y2)))
    print("前向输出:", [tuple(p.shape) for p in _parts(y)],
          "| BN 融合等价性 max|Δ| =", max_diff)
    assert max_diff < 1e-3, "BN 融合不等价!"
    print(f"自测通过: 前向 + BN 融合等价 (type_head={net.type_head})")
