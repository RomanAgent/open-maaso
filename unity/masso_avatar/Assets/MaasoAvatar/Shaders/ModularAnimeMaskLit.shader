Shader "Maaso/Avatar/Modular Anime Mask Lit"
{
    Properties
    {
        [MainTexture] _BaseMap ("RGB Color Mask", 2D) = "white" {}
        [MainColor] _Color ("Fallback Color", Color) = (1, 1, 1, 1)
        _Color_A ("Mask Red Color", Color) = (1, 1, 1, 1)
        _Color_B ("Mask Green Color", Color) = (1, 1, 1, 1)
        _Color_C ("Mask Blue Color", Color) = (1, 1, 1, 1)
        _Color_A_1 ("Mask Red Shadow", Color) = (0.5, 0.25, 0.25, 1)
        _Color_A_2 ("Mask Red Base", Color) = (1, 0.8, 0.73, 1)
        _Color_B_1 ("Mask Green Shadow", Color) = (0.35, 0.25, 0.2, 1)
        _Color_B_2 ("Mask Green Base", Color) = (0.8, 0.8, 0.8, 1)
        _Color_C_1 ("Mask Blue Shadow", Color) = (0, 0, 0, 1)
        _Color_C_2 ("Mask Blue Base", Color) = (0, 0, 0, 1)
        _MaskRemap ("Mask Remap", Vector) = (0.4, 1, 0, 0)
        _Mask_Factor ("Mask Selection Threshold", Range(0.02, 1)) = 0.45
        [Normal] _BumpMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Strength", Range(0, 2)) = 1
        [HideInInspector] _UseMask ("Use Color Mask", Float) = 1
    }

    SubShader
    {
        Tags
        {
            "Queue" = "Geometry"
            "RenderType" = "Opaque"
        }
        LOD 200
        Cull Back

        CGPROGRAM
        #pragma surface surf Lambert fullforwardshadows addshadow
        #pragma target 3.0

        sampler2D _BaseMap;
        sampler2D _BumpMap;
        fixed4 _Color;
        fixed4 _Color_A;
        fixed4 _Color_B;
        fixed4 _Color_C;
        fixed4 _Color_A_1;
        fixed4 _Color_A_2;
        fixed4 _Color_B_1;
        fixed4 _Color_B_2;
        fixed4 _Color_C_1;
        fixed4 _Color_C_2;
        half4 _MaskRemap;
        half _Mask_Factor;
        half _BumpScale;
        half _UseMask;

        struct Input
        {
            float2 uv_BaseMap;
            float2 uv_BumpMap;
        };

        half RemapMaskChannel(half value)
        {
            half range = max(_MaskRemap.y - _MaskRemap.x, 0.0001h);
            return saturate((value - _MaskRemap.x) / range);
        }

        void surf(Input input, inout SurfaceOutput output)
        {
            fixed4 mask = tex2D(_BaseMap, input.uv_BaseMap);
            half selectionThreshold = max(_Mask_Factor, 0.0001h);
            half selectA = smoothstep(0, selectionThreshold, mask.r);
            half selectB = smoothstep(0, selectionThreshold, mask.g);
            half selectC = smoothstep(0, selectionThreshold, mask.b);

            fixed3 paletteA = lerp(
                _Color_A_1.rgb,
                _Color_A_2.rgb,
                RemapMaskChannel(mask.r));
            fixed3 paletteB = lerp(
                _Color_B_1.rgb,
                _Color_B_2.rgb,
                RemapMaskChannel(mask.g));
            fixed3 paletteC = lerp(
                _Color_C_1.rgb,
                _Color_C_2.rgb,
                RemapMaskChannel(mask.b));

            fixed3 mappedColor = lerp(
                _Color_A_1.rgb,
                paletteA,
                selectA);
            mappedColor = lerp(mappedColor, paletteB, selectB);
            mappedColor = lerp(mappedColor, paletteC, selectC);
            output.Albedo = lerp(
                _Color.rgb,
                mappedColor,
                saturate(_UseMask));

            fixed3 normal = UnpackNormal(tex2D(_BumpMap, input.uv_BumpMap));
            normal.xy *= _BumpScale;
            output.Normal = normalize(normal);
            output.Alpha = 1;
        }
        ENDCG
    }

    Fallback "Diffuse"
}
