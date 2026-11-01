Shader "Hidden/Maaso/PortraitDepthOfField"
{
    Properties
    {
        _MainTex ("Source", 2D) = "white" {}
        _MaskMainTex ("Subject alpha", 2D) = "white" {}
        _MaskOpacity ("Subject opacity", Range(0, 1)) = 1
        _MaskCutoff ("Subject alpha cutoff", Range(0, 1)) = 0.02
        _PortraitStrength ("Portrait transition strength", Range(0, 1)) = 1
    }
    SubShader
    {
        Cull Off ZWrite Off ZTest Always
        CGINCLUDE
        #include "UnityCG.cginc"
        sampler2D _MainTex;
        float4 _MainTex_TexelSize;
        sampler2D _BlurredBackground;
        sampler2D _SubjectMask;
        UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);
        float _BackgroundStart;
        float _BackgroundTransition;
        float _PortraitStrength;
        float4 _BlurDirection;
        float4 _BlurWeightsA;
        float4 _BlurWeightsB;

        float2 DepthUV(float2 uv)
        {
            #if UNITY_UV_STARTS_AT_TOP
            if (_MainTex_TexelSize.y < 0) uv.y = 1 - uv.y;
            #endif
            return uv;
        }

        float FarWeight(float2 uv)
        {
            float2 depthUV = DepthUV(uv);
            float depth = LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, depthUV));
            float progress = saturate((depth - _BackgroundStart) / max(0.1, _BackgroundTransition));
            float silhouette = tex2D(_SubjectMask, depthUV).r;
            return progress * progress * (3 - 2 * progress) * (1 - silhouette);
        }

        float4 ExtractBackground(v2f_img input) : SV_Target
        {
            float coverage = FarWeight(input.uv);
            return float4(tex2D(_MainTex, input.uv).rgb * coverage, coverage);
        }

        float4 BlurBackground(v2f_img input) : SV_Target
        {
            // Premultiplied coverage excludes the avatar from both blur passes,
            // preventing skin or dark hair from bleeding into the room edges.
            float2 stepUV = _BlurDirection.xy;
            return tex2D(_MainTex, input.uv) * _BlurWeightsA.x +
                (tex2D(_MainTex, input.uv + stepUV) +
                 tex2D(_MainTex, input.uv - stepUV)) * _BlurWeightsA.y +
                (tex2D(_MainTex, input.uv + stepUV * 2) +
                 tex2D(_MainTex, input.uv - stepUV * 2)) * _BlurWeightsA.z +
                (tex2D(_MainTex, input.uv + stepUV * 3) +
                 tex2D(_MainTex, input.uv - stepUV * 3)) * _BlurWeightsA.w +
                (tex2D(_MainTex, input.uv + stepUV * 4) +
                 tex2D(_MainTex, input.uv - stepUV * 4)) * _BlurWeightsB.x +
                (tex2D(_MainTex, input.uv + stepUV * 5) +
                 tex2D(_MainTex, input.uv - stepUV * 5)) * _BlurWeightsB.y +
                (tex2D(_MainTex, input.uv + stepUV * 6) +
                 tex2D(_MainTex, input.uv - stepUV * 6)) * _BlurWeightsB.z;
        }

        float4 CompositePortrait(v2f_img input) : SV_Target
        {
            float4 original = tex2D(_MainTex, input.uv);
            float4 blurred = tex2D(_BlurredBackground, input.uv);
            float weight = FarWeight(input.uv) * step(0.0001, blurred.a) * saturate(_PortraitStrength);
            float3 background = blurred.rgb / max(blurred.a, 0.0001);
            return float4(lerp(original.rgb, background, weight), original.a);
        }
        ENDCG

        Pass
        {
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment ExtractBackground
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment BlurBackground
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment CompositePortrait
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            // Alpha-tested silhouette is independent of the avatar's depth pass.
            // Max blending keeps overlapping transparent hair strands covered.
            Blend One One
            BlendOp Max
            CGPROGRAM
            #pragma vertex SubjectVertex
            #pragma fragment SubjectFragment
            #pragma target 3.0
            sampler2D _MaskMainTex;
            float4 _MaskMainTex_ST;
            float _MaskOpacity;
            float _MaskCutoff;
            struct SubjectInput { float4 vertex : POSITION; float2 uv : TEXCOORD0; };
            struct SubjectOutput { float4 position : SV_POSITION; float2 uv : TEXCOORD0; };
            SubjectOutput SubjectVertex(SubjectInput input)
            {
                SubjectOutput output;
                output.position = UnityObjectToClipPos(input.vertex);
                output.uv = TRANSFORM_TEX(input.uv, _MaskMainTex);
                return output;
            }
            float4 SubjectFragment(SubjectOutput input) : SV_Target
            {
                clip(tex2D(_MaskMainTex, input.uv).a * _MaskOpacity - _MaskCutoff);
                return 1;
            }
            ENDCG
        }
    }
    Fallback Off
}
