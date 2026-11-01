Shader "Maaso/Mobile Day Sky"
{
    Properties
    {
        _Tint ("Tint", Color) = (1, 1, 1, 1)
        _Exposure ("Exposure", Range(0, 8)) = 1
        _ZenithColor ("Zenith", Color) = (0.34, 0.69, 0.96, 1)
        _HorizonColor ("Horizon", Color) = (0.78, 0.91, 1, 1)
    }

    SubShader
    {
        Tags
        {
            "Queue" = "Background"
            "RenderType" = "Background"
            "PreviewType" = "Skybox"
        }
        Cull Off
        ZWrite Off

        Pass
        {
            CGPROGRAM
            #pragma target 2.0
            #pragma vertex Vert
            #pragma fragment Frag

            #include "UnityCG.cginc"

            fixed4 _Tint;
            half _Exposure;
            fixed4 _ZenithColor;
            fixed4 _HorizonColor;

            struct Attributes
            {
                float4 position : POSITION;
            };

            struct Varyings
            {
                float4 position : SV_POSITION;
                half3 direction : TEXCOORD0;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.position = UnityObjectToClipPos(input.position);
                output.direction = mul(
                    (float3x3)unity_ObjectToWorld,
                    input.position.xyz);
                return output;
            }

            fixed4 Frag(Varyings input) : SV_Target
            {
                float3 direction = normalize(input.direction);
                float viewHeight = -direction.y;
                float skyHeight = saturate(viewHeight);
                float gradient = pow(skyHeight, 0.55);
                float3 sky = lerp(
                    _HorizonColor.rgb,
                    _ZenithColor.rgb,
                    gradient);
                sky *= _Tint.rgb * _Exposure;
                return fixed4(saturate(sky), 1.0);
            }
            ENDCG
        }
    }

    Fallback Off
}
