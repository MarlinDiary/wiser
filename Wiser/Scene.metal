//
//  Scene.metal
//  Wiser
//
//  Created by Marlin on 19/10/2026.
//

#include <metal_stdlib>
using namespace metal;

struct SceneVertex {
    float4 position [[position]];
};

/// One triangle that covers the whole view.
vertex SceneVertex sceneVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    SceneVertex out;
    out.position = float4(corner * 2 - 1, 0, 1);
    return out;
}

/// The scene, as it was last drawn.
fragment half4 copyFragment(SceneVertex in [[stage_in]], texture2d<half, access::read> background [[texture(0)]]) {
    return half4(background.read(uint2(in.position.xy)).rgb, 1);
}
