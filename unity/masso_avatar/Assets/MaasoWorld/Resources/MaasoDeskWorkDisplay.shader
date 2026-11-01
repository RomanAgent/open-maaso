Shader "Maaso/DeskWorkDisplay"
{
    Properties { _MainTex ("Local working visualization", 2D) = "white" {} }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry+1" }
        Pass
        {
            Cull Back
            ZWrite On
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 2.0
            #include "UnityCG.cginc"
            sampler2D _MainTex;
            struct input { float4 vertex : POSITION; float2 uv : TEXCOORD0; };
            struct output { float4 vertex : SV_POSITION; float2 uv : TEXCOORD0; };
            output vert(input value)
            {
                output result;
                result.vertex = UnityObjectToClipPos(value.vertex);
                result.uv = value.uv;
                return result;
            }
            fixed4 frag(output value) : SV_Target { return tex2D(_MainTex, value.uv); }
            ENDCG
        }
    }
    Fallback Off
}
