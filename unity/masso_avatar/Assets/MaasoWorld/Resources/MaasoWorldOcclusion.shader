Shader "Hidden/Maaso/WorldOcclusion"
{
    Properties
    {
        _Color ("Color", Color) = (1, 1, 1, 1)
        _MainTex ("Albedo", 2D) = "white" {}
        _Metallic ("Metallic", Range(0, 1)) = 0
        _Glossiness ("Smoothness", Range(0, 1)) = 0.5
        _GlossMapScale ("Smoothness Scale", Range(0, 1)) = 1
        _MetallicGlossMap ("Metallic (R) Smoothness (A)", 2D) = "white" {}
        [Normal] _BumpMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Scale", Float) = 1
        _OcclusionMap ("Occlusion", 2D) = "white" {}
        _OcclusionStrength ("Occlusion Strength", Range(0, 1)) = 1
        [HDR] _EmissionColor ("Emission Color", Color) = (0, 0, 0, 0)
        _EmissionMap ("Emission", 2D) = "white" {}
        _OcclusionOpacity ("Occlusion Opacity", Range(0, 1)) = 1
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" }
        LOD 300
        Cull Back
        ZWrite On
        Blend Off

        CGPROGRAM
        #pragma target 3.0
        #pragma surface surf Standard fullforwardshadows exclude_path:deferred nometa

        // These materials are created at runtime; shader_feature variants could
        // otherwise be stripped when no authored material uses this shader.
        #pragma multi_compile_local _ _NORMALMAP
        #pragma multi_compile_local _ _METALLICGLOSSMAP
        #pragma multi_compile_local _ _EMISSION
        #pragma multi_compile_local _ _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
        #pragma multi_compile_local _ _SPECULARHIGHLIGHTS_OFF
        #pragma multi_compile_local _ _GLOSSYREFLECTIONS_OFF

        #include "UnityStandardUtils.cginc"

        sampler2D _MainTex;
        sampler2D _MetallicGlossMap;
        sampler2D _BumpMap;
        sampler2D _OcclusionMap;
        sampler2D _EmissionMap;
        fixed4 _Color;
        half _Metallic;
        half _Glossiness;
        half _GlossMapScale;
        half _BumpScale;
        half _OcclusionStrength;
        half3 _EmissionColor;
        half _OcclusionOpacity;

        struct Input
        {
            float2 uv_MainTex;
            float4 screenPos;
        };

        float BayerThreshold(float2 pixelPosition)
        {
            float2 cell = floor(fmod(pixelPosition, 4.0));
            float4 row = cell.y < 1.0 ? float4(0, 8, 2, 10) :
                cell.y < 2.0 ? float4(12, 4, 14, 6) :
                cell.y < 3.0 ? float4(3, 11, 1, 9) :
                float4(15, 7, 13, 5);
            float rank = cell.x < 1.0 ? row.x :
                cell.x < 2.0 ? row.y :
                cell.x < 3.0 ? row.z : row.w;

            // Midpoint thresholds make 0 entirely absent and 1 fully opaque.
            // A fixed screen-space grid has no temporal noise or alpha sorting.
            return (rank + 0.5) / 16.0;
        }

        void surf(Input input, inout SurfaceOutputStandard output)
        {
            float2 pixelPosition = input.screenPos.xy /
                max(input.screenPos.w, 0.00001) * _ScreenParams.xy;
            clip(_OcclusionOpacity - BayerThreshold(pixelPosition));

            // Standard uses the albedo UV transform for its primary maps.
            fixed4 albedo = tex2D(_MainTex, input.uv_MainTex);
            output.Albedo = albedo.rgb * _Color.rgb;
            output.Alpha = 1;

            #if defined(_METALLICGLOSSMAP)
                half4 metallicGloss = tex2D(_MetallicGlossMap, input.uv_MainTex);
                output.Metallic = metallicGloss.r;
                output.Smoothness = metallicGloss.a * _GlossMapScale;
            #else
                output.Metallic = _Metallic;
                output.Smoothness = _Glossiness;
            #endif

            #if defined(_SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A)
                output.Smoothness = albedo.a * _GlossMapScale;
            #endif

            #if defined(_NORMALMAP)
                output.Normal = UnpackScaleNormal(
                    tex2D(_BumpMap, input.uv_MainTex), _BumpScale);
            #endif

            output.Occlusion = lerp(1.0,
                tex2D(_OcclusionMap, input.uv_MainTex).g, _OcclusionStrength);

            #if defined(_EMISSION)
                output.Emission = tex2D(_EmissionMap, input.uv_MainTex).rgb *
                    _EmissionColor;
            #endif
        }
        ENDCG

        // Keep the original solid architectural shadows while fading its
        // camera-facing pixels. Do not add a generated, dithered shadow pass.
        UsePass "Standard/SHADOWCASTER"
    }
    Fallback Off
}
