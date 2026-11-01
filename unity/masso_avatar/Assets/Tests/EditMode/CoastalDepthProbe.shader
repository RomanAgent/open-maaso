// Editor regression probe. No Resources or production material references.
Shader "Hidden/Maaso/Tests/CoastalDepthProbe"
{
    SubShader
    {
        Pass
        {
            Cull Off ZWrite Off ZTest Always
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag
            #pragma target 3.0
            #include "UnityCG.cginc"
            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);
            float frag(v2f_img input) : SV_Target
            {
                return LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, input.uv));
            }
            ENDCG
        }
    }
    Fallback Off
}
