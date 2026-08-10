#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Настоящая "капля воды" на GPU-шейдере (colorEffect), а не CPU-приём
// blur+contrast. Шейдер сам считает форму (эллипс с "дыханием" по времени),
// объём (затемнение к краю), блик и тонкий ободок — процедурно, попиксельно.
// Применяется к произвольной сплошной фигуре (её собственный цвет не важен,
// шейдер целиком переопределяет цвет/альфу).
[[ stitchable ]]
half4 waterDroplet(float2 position, half4 color, float2 size, float time) {
    float2 center = size * 0.5;
    float2 p = position - center;

    // Радиусы с лёгким несинхронным "дыханием" — форма живая, не идеально статичная.
    float rx = (size.x * 0.5) * (1.0 + 0.07 * sin(time * 2.3));
    float ry = (size.y * 0.5) * (1.0 - 0.06 * sin(time * 3.1 + 0.6));

    float2 n = float2(p.x / max(rx, 1.0), p.y / max(ry, 1.0));
    float dist = length(n); // 0 в центре капли, 1 на границе эллипса

    if (dist > 1.2) {
        return half4(0.0);
    }

    // Мягкий эллиптический край.
    float edgeAlpha = 1.0 - smoothstep(0.78, 1.02, dist);

    // Голубовато-белая вода (не акцентный цвет приложения), с затемнением
    // к краю — создаёт ощущение объёма/толщины капли.
    half3 base = half3(0.70, 0.86, 1.0);
    float shade = smoothstep(0.0, 1.0, dist);
    half3 shaded = mix(base, base * 0.5, shade * 0.55);

    // Подвижный блик сверху-слева (смещается вместе с "дыханием" формы).
    float2 highlightCenter = float2(-0.32, -0.38);
    float highlightDist = length(n - highlightCenter);
    float highlight = smoothstep(0.55, 0.0, highlightDist);
    shaded += half3(highlight * 0.95);

    // Тонкий светлый ободок по самому краю — держит силуэт читаемым
    // на тёмном фоне панели.
    float rim = smoothstep(0.68, 0.94, dist) * (1.0 - smoothstep(0.94, 1.06, dist));
    shaded += half3(rim * 0.45);

    half alpha = half(edgeAlpha) * 0.9;
    return half4(shaded * alpha, alpha);
}
