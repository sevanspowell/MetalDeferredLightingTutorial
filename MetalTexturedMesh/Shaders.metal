/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    Shader file with functions for rendering lit, textured geometry.
*/

#include <metal_stdlib>
using namespace metal;

struct Constants {
    float4x4 modelViewProjectionMatrix;
    float3x3 normalMatrix;
    float4x4 modelMatrix;
};

constant half3 ambientLightIntensity(0.1, 0.1, 0.1);
constant half3 diffuseLightIntensity(0.9, 0.9, 0.9);
constant half3 lightDirection(-0.577, -0.577, -0.577);

struct VertexIn {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 texCoords;
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float2 texCoords;
    float4 worldPosition;
};

struct StencilPassOut {
    float4 position [[position]];
};

vertex StencilPassOut stencilPassVert(const device VertexIn *vertices [[buffer(0)]],
                                      const device Constants &uniforms [[buffer(1)]],
                                      unsigned int vid [[vertex_id]]) {
    StencilPassOut out;
    
    out.position = uniforms.modelViewProjectionMatrix * float4(vertices[vid].position, 1.0);
    
    return out;
}

fragment void stencilPassNullFrag(StencilPassOut in [[stage_in]])
{
}

struct LightFragmentInput {
    float2 screenSize;
    float3 camWorldPos;
};

struct PointLight {
    float3 worldPosition;
    float radius;
    float3 color;
};

fragment float4 lightVolumeFrag(StencilPassOut in [[stage_in]],
                                constant LightFragmentInput *lightData [[ buffer(0) ]],
                                constant PointLight *pointLight [[ buffer(1) ]],
                                texture2d<float> albedoTexture [[ texture(0) ]],
                                texture2d<float> normalsTexture [[ texture(1) ]],
                                texture2d<float> positionTexture [[ texture(2) ]])
{
    // We sample albedo, normals and position from the position of this fragment, normalized to be 0-1 within screen space
    float2 sampleCoords = in.position.xy / lightData->screenSize;
    
    constexpr sampler texSampler;
    
    // Extract data for this fragment from GBuffer textures
    const float3 albedo = float3(albedoTexture.sample(texSampler, sampleCoords));
    const float3 worldPosition = float3(positionTexture.sample(texSampler, sampleCoords));
    const float3 normal = normalize(float3(normalsTexture.sample(texSampler, sampleCoords)));

    const float3 lightDir = normalize(pointLight->worldPosition - worldPosition);
    
    // Diffuse
    const float nDotL = max(dot(normal, lightDir), 0.0);
    const float3 diffuse = nDotL * albedo * pointLight->color;
    
    float3 result = diffuse;
    
    // Specular - if you want
    //const float3 viewDir = normalize(lightData->camWorldPos - worldPosition);
    //const float3 halfwayDir = normalize(lightDir + viewDir);
    //const float3 specular = pow(max(dot(normal, halfwayDir), 0.0), 60.0) * 0.2;
    //result = (diffuse + specular);
    
    const float3 gammaCorrect = pow(float3(result), (1.0/2.2));
    return float4(gammaCorrect, 1.0);
}

struct GBufferOut {
    float4 albedo [[color(0)]];
    float4 normal [[color(1)]];
    float4 position [[color(2)]];
};

vertex VertexOut gBufferVert(const device VertexIn *vertices [[buffer(0)]],
                             const device Constants &uniforms [[buffer(1)]],
                             unsigned int vid [[vertex_id]]) {
    VertexOut out;
    VertexIn vin = vertices[vid];
    
    float4 inPosition = float4(vin.position, 1.0);
    out.position = uniforms.modelViewProjectionMatrix * inPosition;
    float3 normal = vin.normal;
    float3 eyeNormal = normalize(uniforms.normalMatrix * normal);
    
    out.normal = eyeNormal;
    out.texCoords = vin.texCoords;
    out.worldPosition = uniforms.modelMatrix * inPosition;
    
    return out;
}

fragment GBufferOut gBufferFrag(VertexOut in [[stage_in]],
                                texture2d<float> albedo_texture [[texture(0)]])
{
    constexpr sampler linear_sampler(min_filter::linear, mag_filter::linear);
    float4 albedo = albedo_texture.sample(linear_sampler, in.texCoords);
    
    GBufferOut output;
    
    output.albedo = albedo;
    output.normal = float4(in.normal, 1.0);
    output.position = in.worldPosition;

    return output;
}

vertex VertexOut vertex_transform(device VertexIn *vertices [[buffer(0)]],
                                  constant Constants &uniforms [[buffer(1)]],
                                  uint vertexId [[vertex_id]])
{
    float3 modelPosition = vertices[vertexId].position;
    float3 modelNormal = vertices[vertexId].normal;
    
    VertexOut out;
    // Multiplying the model position by the model-view-projection matrix moves us into clip space
    out.position = uniforms.modelViewProjectionMatrix * float4(modelPosition, 1);
    // Copy the vertex normal and texture coordinates
    out.normal = uniforms.normalMatrix * modelNormal;
    out.texCoords = vertices[vertexId].texCoords;
    return out;
}

fragment half4 fragment_lit_textured(VertexOut fragmentIn [[stage_in]],
                                     texture2d<float, access::sample> tex2d [[texture(0)]],
                                     sampler sampler2d [[sampler(0)]])
{
    // Sample the texture to get the surface color at this point
    half3 surfaceColor = half3(tex2d.sample(sampler2d, fragmentIn.texCoords).rrr);
    // Re-normalize the interpolated surface normal
    half3 normal = normalize(half3(fragmentIn.normal));
    // Compute the ambient color contribution
    half3 color = ambientLightIntensity * surfaceColor;
    // Calculate the diffuse factor as the dot product of the normal and light direction
    float diffuseFactor = saturate(dot(normal, -lightDirection));
    // Add in the diffuse contribution from the light
    color += diffuseFactor * diffuseLightIntensity * surfaceColor;
    return half4(color, 1);
}
