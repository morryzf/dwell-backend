// 雨打在玻璃上：对聊天背景逐像素折射的 SwiftUI layerEffect。
//
// 思路来自 codrops/RainEffect（KiraKiraAyu 的 WebGPU 重写同款）：真实感不在「画水珠」，
// 而在水珠内部按它的法线去采样背景——透过每颗水珠看到的是缩小、倒置、更亮的壁纸。
// 这里不用贴图，所有水珠都从 (格子, 时间) 的哈希现场算出来：
//   · 一层会滑落的大珠：走走停停，左右摇，身后留一串越来越小的痕；
//   · 两层停着的小珠：大小按平方分布（小的多大的少），各自慢慢出现又干掉；
// 形状靠纵向拉长和摇摆打破圆形。坐标全用 pt，和 SwiftUI 一边大。

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float2 hash22(float2 p) {
    float3 q = fract(float3(p.xyx) * float3(443.897, 441.423, 437.195));
    q += dot(q, q.yzx + 19.19);
    return fract((q.xx + q.yz) * q.zy);
}

// 一颗水珠对这个像素的影响：mask（0..1，带软边）和指向珠心的偏移（折射用）。
// stretch>1 时上下拉长，像挂在玻璃上被重力扯着。
struct DropHit {
    float mask;
    float2 toCenter;   // 以半径为单位
    float radius;
};

static DropHit dropAt(float2 p, float2 center, float radius, float stretch) {
    DropHit hit;
    float2 d = (p - center) / float2(radius, radius * stretch);
    float len = length(d);
    hit.mask = 1.0 - smoothstep(0.72, 1.0, len);
    hit.toCenter = -d;        // 从像素指回珠心
    hit.radius = radius;
    return hit;
}

static void takeBest(thread DropHit &best, DropHit candidate) {
    if (candidate.mask > best.mask) { best = candidate; }
}

// 停着的小珠：cell 一格最多一颗，位置、大小、寿命都从哈希来。
// density 0..1：雨越大越多格子里真的有珠。
static DropHit stillLayer(float2 p, float cell, float density, float time, float salt) {
    DropHit best = { 0.0, float2(0.0), 1.0 };
    float2 base = floor(p / cell);
    for (int ix = -1; ix <= 1; ix++) {
        for (int iy = -1; iy <= 1; iy++) {
            float2 id = base + float2(ix, iy);
            float2 h = hash22(id * 1.37 + salt);
            if (h.x > density) { continue; }
            // 每颗珠按自己的节拍活一轮：长出来，待着，慢慢干掉，再换个样子重来。
            float period = 14.0 + 20.0 * h.y;
            float cycles = floor(time / period + h.x * 7.0);
            float phase = fract(time / period + h.x * 7.0);
            float2 jitter = hash22(id + cycles * 0.731 + salt);
            float2 center = (id + 0.15 + jitter * 0.7) * cell;
            // 平方分布：多数很小，偶尔一颗大的。
            float radius = cell * (0.10 + 0.26 * jitter.y * jitter.y);
            float alive = smoothstep(0.0, 0.08, phase) * (1.0 - smoothstep(0.75, 1.0, phase));
            DropHit hit = dropAt(p, center, radius, 1.12 + 0.3 * jitter.x);
            hit.mask *= alive;
            takeBest(best, hit);
        }
    }
    return best;
}

// 会滑落的大珠：一条竖栏里一颗，走走停停往下出溜，路线左右摇；
// 身后沿着来路留一串小珠，离头越远越小、越淡，像正在干掉的水痕。
static DropHit slidingLayer(float2 p, float2 bounds, float density, float time) {
    DropHit best = { 0.0, float2(0.0), 1.0 };
    float colW = 96.0;
    float col = floor(p.x / colW);
    for (int ic = -1; ic <= 1; ic++) {
        float column = col + float(ic);
        float2 h = hash22(float2(column, 4.7));
        if (h.y > density) { continue; }
        float period = 7.0 + 9.0 * h.x;                     // 这栏多久滑一颗
        float round = floor(time / period + h.y);
        float progress = fract(time / period + h.y);
        float2 g = hash22(float2(column, round * 0.613));
        // 头 15% 先鼓着不动（攒重量），然后加速往下，走的时候还一顿一顿。
        float travel = smoothstep(0.15, 1.0, progress);
        travel = travel * travel;
        float lurch = 0.012 * sin(time * 9.0 + g.x * 40.0);
        float headY = (travel + lurch) * (bounds.y + 120.0) - 60.0;
        // 路线：绕着栏中心左右摇。
        float pathX0 = (column + 0.25 + 0.5 * g.y) * colW;
        float sway = colW * 0.16;
        float headX = pathX0 + sway * sin(headY * 0.021 + g.x * 6.28);
        float headR = 6.5 + 3.5 * g.y;
        // 头：滑得越快拉得越长。
        float speedStretch = 1.25 + 0.9 * travel;
        takeBest(best, dropAt(p, float2(headX, headY), headR, speedStretch));

        // 痕：头上方每隔一小段一颗，越远越小，最远的已经快干了。
        if (p.y < headY && progress > 0.15) {
            float step = 22.0;
            float cellY = floor(p.y / step);
            float2 th = hash22(float2(column, cellY) + round);
            float y = (cellY + 0.3 + 0.4 * th.y) * step;
            float behind = (headY - y) / 320.0;
            if (behind > 0.0 && behind < 1.0) {
                float x = pathX0 + sway * sin(y * 0.021 + g.x * 6.28) + (th.x - 0.5) * 5.0;
                float radius = max(1.6, headR * 0.55 * (1.0 - behind) * (0.5 + th.y));
                DropHit trail = dropAt(p, float2(x, y), radius, 1.2);
                trail.mask *= 1.0 - behind * 0.7;
                takeBest(best, trail);
            }
        }
    }
    return best;
}

[[ stitchable ]] half4 rainOnGlass(float2 position, SwiftUI::Layer layer,
                                   float4 bounds, float time, float level,
                                   float dark, float fade) {
    if (fade <= 0.001) { return layer.sample(position); }
    float2 size = bounds.zw;

    // 雨量：停珠的密度、滑珠的密度一起涨。
    float still1 = 0.32 + 0.18 * level;     // 大格，珠子也大些
    float still2 = 0.38 + 0.20 * level;     // 小格的细密水雾
    float slide = 0.45 + 0.25 * level;

    DropHit best = slidingLayer(position, size, slide, time);
    takeBest(best, stillLayer(position, 54.0, still1, time, 3.1));
    takeBest(best, stillLayer(position, 26.0, still2, time * 0.8, 8.7));

    float mask = best.mask * fade;
    if (mask <= 0.003) { return layer.sample(position); }

    // 折射：往珠心的反方向采样，画面在珠里是倒着缩小的；珠越大偏得越远。
    float refract = best.radius * (1.1 + 0.9 * level * 0.3);
    float2 offset = best.toCenter * refract * 1.6;
    half4 through = layer.sample(position + offset * mask);
    half4 flat = layer.sample(position);
    half4 color = mix(flat, through, half(mask));

    // 玻璃感的三笔：珠里略亮、顶边一道暗沿（厚度）、偏左上一粒高光。
    float brighten = dark > 0.5 ? 0.10 : 0.07;
    color.rgb *= half(1.0 + brighten * mask);
    float topRim = smoothstep(0.2, 0.95, -best.toCenter.y) * smoothstep(1.0, 0.72, length(best.toCenter));
    color.rgb *= half(1.0 - 0.16 * topRim * mask);
    float2 shineAt = best.toCenter - float2(-0.42, -0.45);
    float shine = 1.0 - smoothstep(0.0, 0.34, length(shineAt));
    color.rgb += half(shine * mask * (dark > 0.5 ? 0.38 : 0.5));

    return color;
}
