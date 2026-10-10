//
//  StoneTint.metal
//  Wiser
//
//  Created by Marlin on 10/10/2026.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Gives gray artwork the hue of `tint` while keeping each pixel's brightness,
// so the stones take on the color of the sky without turning muddy.
[[ stitchable ]] half4 tintKeepingLuminance(float2 position, half4 color, half4 tint, float amount) {
    if (color.a <= 0.0h) {
        return color;
    }
    const half3 weights = half3(0.2126h, 0.7152h, 0.0722h);
    half3 rgb = color.rgb / color.a;
    half luminance = dot(rgb, weights);
    half tintLuminance = max(dot(tint.rgb, weights), 0.001h);
    half3 tinted = clamp(tint.rgb * (luminance / tintLuminance), 0.0h, 1.0h);
    half3 result = mix(rgb, tinted, half(amount));
    return half4(result * color.a, color.a);
}
