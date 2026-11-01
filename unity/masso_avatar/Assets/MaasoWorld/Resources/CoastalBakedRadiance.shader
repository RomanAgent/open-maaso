Shader "Maaso/CoastalBakedRadiance"
{
    Properties
    {
        _Color ("Opacity (A)", Color) = (0, 0, 0, 1)
        _MainTex ("Atlas alpha", 2D) = "white" {}
        _EmissionMap ("Baked radiance (sRGB)", 2D) = "white" {}
        _EmissionColor ("Radiance multiplier", Color) = (1, 1, 1, 1)
        [HideInInspector] _Mode ("Mode", Float) = 0
        [HideInInspector] _SrcBlend ("Source blend", Float) = 1
        [HideInInspector] _DstBlend ("Destination blend", Float) = 0
        [HideInInspector] _ZWrite ("Depth write", Float) = 1
        [HideInInspector] _OcclusionOpacity ("Cutaway coverage", Range(0, 1)) = 1
        _DynamicShadowStrength ("Dynamic contact shadow", Range(0, 1)) = 0
        // Keep the narrow importer/occlusion material contract compatible.
        [HideInInspector] _Metallic ("Metallic", Float) = 0
        [HideInInspector] _Glossiness ("Smoothness", Float) = 0
        [HideInInspector] _GlossyReflections ("Reflections", Float) = 0
        [HideInInspector] _SpecularHighlights ("Highlights", Float) = 0
        [HideInInspector] _BumpMap ("Normal", 2D) = "bump" {}
        [HideInInspector] _MetallicGlossMap ("Metallic map", 2D) = "white" {}
        [HideInInspector] _OcclusionMap ("Occlusion map", 2D) = "white" {}
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" }
        CGINCLUDE
        #include "UnityCG.cginc"
        half _OcclusionOpacity;
        float CutawayThreshold(float2 pixel)
        {
            float2 cell = floor(fmod(pixel, 4.0));
            float4 row = cell.y < 1.0 ? float4(0, 8, 2, 10) :
                cell.y < 2.0 ? float4(12, 4, 14, 6) :
                cell.y < 3.0 ? float4(3, 11, 1, 9) : float4(15, 7, 13, 5);
            float rank = cell.x < 1.0 ? row.x : cell.x < 2.0 ? row.y :
                cell.x < 3.0 ? row.z : row.w;
            return (rank + 0.5) / 16.0;
        }
        ENDCG
        Pass
        {
            Tags { "LightMode" = "ForwardBase" }
            Cull Back
            ZWrite [_ZWrite]
            Blend [_SrcBlend] [_DstBlend]
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0
            #pragma multi_compile_fwdbase nolightmap nodirlightmap nodynlightmap novertexlight
            #include "UnityCG.cginc"
            #include "AutoLight.cginc"
            sampler2D _MainTex;
            sampler2D _EmissionMap;
            float4 _MainTex_ST;
            half4 _Color;
            half4 _EmissionColor;
            half _DynamicShadowStrength;
            // Global, not a material property: every room/cutaway clone follows
            // the lighting controller, including rooms loaded after night starts.
            half _MaasoWorldNightBlend;

            struct VertexInput { float4 vertex : POSITION; float2 uv : TEXCOORD0; };
            struct VertexOutput
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                float4 screenPosition : TEXCOORD1;
                SHADOW_COORDS(2)
            };
            VertexOutput vert(VertexInput v)
            {
                VertexOutput output;
                output.pos = UnityObjectToClipPos(v.vertex);
                output.uv = TRANSFORM_TEX(v.uv, _MainTex);
                output.screenPosition = ComputeScreenPos(output.pos);
                TRANSFER_SHADOW(output)
                return output;
            }
            half4 frag(VertexOutput input) : SV_Target
            {
                float2 pixel = input.screenPosition.xy /
                    max(input.screenPosition.w, 0.00001) * _ScreenParams.xy;
                clip(_OcclusionOpacity - CutawayThreshold(pixel));
                // sRGB textures decode during sampling, and the render target
                // encodes on output. No second tone transform, light or fog.
                half3 radiance = tex2D(_EmissionMap, input.uv).rgb * _EmissionColor.rgb;
                radiance *= lerp(half3(1, 1, 1), half3(0.20, 0.26, 0.40),
                    saturate(_MaasoWorldNightBlend));
                // Preserve the baked radiance and its one colour transform.
                // Optional V4 reception adds only the live Avatar/door shadow;
                // static baked geometry remains excluded from light shadows.
                radiance *= lerp(1.0h, SHADOW_ATTENUATION(input), _DynamicShadowStrength);
                half alpha = tex2D(_MainTex, input.uv).a * _Color.a;
                return half4(radiance, alpha);
            }
            ENDCG
        }
        // Built-in camera depth selects ShadowCaster independently of the
        // renderer's light-shadow switch. Importer keeps shadowCastingMode Off:
        // this supplies portrait depth without adding shadows to the avatar.
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            Cull Back
            ZWrite On
            ZTest LEqual
            Blend Off
            ColorMask 0
            CGPROGRAM
            #pragma vertex depthVert
            #pragma fragment depthFrag
            #pragma target 3.0
            #pragma multi_compile_shadowcaster
            half _Mode;
            half _ZWrite;
            struct DepthOutput
            {
                V2F_SHADOW_CASTER;
                float4 screenPosition : TEXCOORD1;
            };
            DepthOutput depthVert(appdata_base v)
            {
                DepthOutput output;
                TRANSFER_SHADOW_CASTER_NORMALOFFSET(output)
                output.screenPosition = ComputeScreenPos(output.pos);
                return output;
            }
            float4 depthFrag(DepthOutput input) : SV_Target
            {
                // Alpha-blended sheers must not become opaque depth blockers,
                // even if a caller accidentally leaves their queue at Geometry.
                clip(0.5 - _Mode);
                clip(_ZWrite - 0.5);
                float2 pixel = input.screenPosition.xy /
                    max(input.screenPosition.w, 0.00001) * _ScreenParams.xy;
                clip(_OcclusionOpacity - CutawayThreshold(pixel));
                SHADOW_CASTER_FRAGMENT(input)
            }
            ENDCG
        }
    }
    Fallback Off
}
