// 雨打在玻璃上：对聊天背景逐像素折射的 SwiftUI layerEffect。
//
// 思路来自 codrops/RainEffect（KiraKiraAyu 的 WebGPU 重写同款）：真实感不在「画水珠」，
// 而在把所有水珠叠成一个「水场」再取等值面——挨着的珠子黏成一团，轮廓就不是圆；
// 核是上薄下鼓的泪滴形，边缘带一点波浪；水珠内部按场的梯度反向采样背景，
// 透过每颗珠看到的是缩小倒置的壁纸。所有珠都从 (格子, 时间) 的哈希现场算出来，
// 没有任何状态。和网页 static/index.html 里的 WebGL 片元着色器是同一套数学，
// 调参先在网页上用截图核对，再同步到这里。坐标全用 pt，和 SwiftUI 一边大。

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float2 hash22(float2 p) {
    float3 q = fract(float3(p.xyx) * float3(443.897, 441.423, 437.195));
    q += dot(q, q.yzx + 19.19);
    return fract((q.xx + q.yz) * q.zy);
}

// 把一颗珠加进水场。acc: x=场强，yz=Σ权重*指回质心，w=Σ权重*半径。
// topThin<1 让上缘收窄（真水珠顶上薄）；wob 给轮廓一点波浪。
static void addDrop(thread float4 &acc, float2 p, float2 center, float radius,
                    float topThin, float wob, float phase, float weight) {
    float2 d = (p - center) / radius;
    if (abs(d.x) > 2.0 || abs(d.y) > 2.0) { return; }
    d.y /= (d.y < 0.0 ? topThin : 1.12);
    float ang = atan2(d.y, d.x);
    float edge = 1.0 + wob * sin(ang * 3.0 + phase) + wob * 0.6 * sin(ang * 5.0 + phase * 1.7);
    float len = length(d) / edge;
    float k = max(0.0, 1.0 - len * len);
    k = k * k * weight;
    acc.x += k;
    acc.yz += -d * k;
    acc.w += radius * k;
}

// 停着的珠子：一格最多一颗，位置、大小、寿命都从哈希来，
// 密度再乘一层低频的斑块起伏——真玻璃上的水从来不是均匀撒的。
static void stillLayer(thread float4 &acc, float2 p, float cell, float density,
                       float time, float salt, float rMin, float rMax, float weight) {
    float2 base = floor(p / cell);
    for (int ix = -1; ix <= 1; ix++) {
        for (int iy = -1; iy <= 1; iy++) {
            float2 id = base + float2(ix, iy);
            float2 h = hash22(id * 1.37 + salt);
            float2 pr = hash22(floor(id * cell / 230.0) + salt * 0.37);
            if (h.x > density * (0.35 + 1.5 * pr.x)) { continue; }
            float period = 14.0 + 20.0 * h.y;
            float cycles = floor(time / period + h.x * 7.0);
            float phase = fract(time / period + h.x * 7.0);
            float2 jitter = hash22(id + cycles * 0.731 + salt);
            float2 center = (id + 0.15 + jitter * 0.7) * cell;
            float radius = cell * mix(rMin, rMax, jitter.y * jitter.y);
            float alive = smoothstep(0.0, 0.08, phase) * (1.0 - smoothstep(0.75, 1.0, phase));
            addDrop(acc, p, center, radius, 0.72 + 0.2 * jitter.x, 0.10,
                    jitter.x * 40.0, weight * alive);
        }
    }
}

// 会滑落的大珠：走走停停往下出溜，头和身后的痕都丢进同一个水场，黏成一条不规则的湿痕。
static void slidingLayer(thread float4 &acc, float2 p, float2 size, float density, float time) {
    float colW = 96.0;
    float col = floor(p.x / colW);
    for (int ic = -1; ic <= 1; ic++) {
        float column = col + float(ic);
        float2 h = hash22(float2(column, 4.7));
        if (h.y > density) { continue; }
        float period = 7.0 + 9.0 * h.x;
        float round = floor(time / period + h.y);
        float progress = fract(time / period + h.y);
        float2 g = hash22(float2(column, round * 0.613));
        float travel = smoothstep(0.15, 1.0, progress);
        travel *= travel;
        float lurch = 0.012 * sin(time * 9.0 + g.x * 40.0);
        float headY = (travel + lurch) * (size.y + 120.0) - 60.0;
        float pathX0 = (column + 0.25 + 0.5 * g.y) * colW;
        float sway = colW * 0.16;
        float headX = pathX0 + sway * sin(headY * 0.021 + g.x * 6.28);
        float headR = 9.0 + 6.0 * g.y;
        addDrop(acc, p, float2(headX, headY), headR, 0.55 - 0.2 * travel, 0.08,
                g.x * 40.0, 1.0);
        if (p.y < headY && progress > 0.15) {
            float cellY = floor(p.y / 22.0);
            float2 th = hash22(float2(column, cellY) + round);
            float y = (cellY + 0.3 + 0.4 * th.y) * 22.0;
            float behind = (headY - y) / 320.0;
            if (behind > 0.0 && behind < 1.0) {
                float x = pathX0 + sway * sin(y * 0.021 + g.x * 6.28) + (th.x - 0.5) * 5.0;
                float radius = max(1.8, headR * 0.62 * (1.0 - behind) * (0.5 + th.y));
                addDrop(acc, p, float2(x, y), radius, 0.45, 0.1, th.x * 40.0,
                        1.0 - behind * 0.7);
            }
        }
    }
}

[[ stitchable ]] half4 rainOnGlass(float2 position, SwiftUI::Layer layer,
                                   float4 bounds, float time, float level,
                                   float dark, float fade) {
    if (fade <= 0.001) { return layer.sample(position); }
    float2 size = bounds.zw;

    float4 acc = float4(0.0);
    slidingLayer(acc, position, size, 0.36 + 0.25 * level, time);
    stillLayer(acc, position, 64.0, 0.24 + 0.12 * level, time, 3.1, 0.13, 0.48, 1.0);
    stillLayer(acc, position, 27.0, 0.30 + 0.14 * level, time * 0.8, 8.7, 0.14, 0.44, 1.0);
    // 细密的水雾斑：很小，大多各自成点，挨上了就黏成一小撮。
    stillLayer(acc, position, 11.0, 0.62 + 0.20 * level, time * 0.6, 15.3, 0.12, 0.34, 0.85);

    float field = acc.x;
    float mask = smoothstep(0.15, 0.27, field) * fade;
    if (mask <= 0.003) { return layer.sample(position); }

    // 折射：场的梯度指回这团水的质心，边上偏得多、中心偏得少。
    float2 grad = acc.yz / max(field, 1e-4);
    float radius = acc.w / max(field, 1e-4);
    float2 offset = grad * radius * 1.7;
    half4 through = layer.sample(position + offset * mask);
    half4 plain = layer.sample(position);
    half4 color = mix(plain, through, half(mask));

    // 玻璃感的三笔：珠里略亮；等值面附近是水边，压一道暗沿，上缘更深
    //（上缘的梯度指向下方的质心，y 是正的）；偏左上一粒小高光。
    color.rgb *= half(1.0 + (dark > 0.5 ? 0.08 : 0.05) * mask);
    float ring = (1.0 - smoothstep(0.27, 0.62, field)) * mask;
    float2 dir = grad / max(length(grad), 1e-4);
    float topness = smoothstep(0.1, 0.9, dir.y);
    color.rgb *= half(1.0 - ring * (0.11 + 0.17 * topness));
    float shine = (1.0 - smoothstep(0.1, 0.5, length(grad - float2(0.38, 0.42)))) * mask;
    color.rgb += half(shine * (dark > 0.5 ? 0.22 : 0.3));

    return color;
}
