Shader "Maaso/Coastal Cloud Volume"
{
    Properties
    {
        _DensityVolume ("Baked density and daylight", 3D) = "" {}
        _VolumeResolution ("Variant resolution and count", Vector) = (128,96,80,2)
        _Extinction ("Extinction per world metre", Range(.1,3)) = 1.8
        _StepCount ("Ray samples", Range(16,56)) = 48
        _SunColor ("Sunlit cloud", Color) = (.98,.96,.92,1)
        _ShadowColor ("Cloud interior", Color) = (.46,.55,.66,1)
        [PerRendererData] _CloudVariant ("Cloud variant", Float) = 0
        [PerRendererData] _DensityMultiplier ("Density multiplier", Float) = 1
    }
    SubShader
    {
        // The ocean is opaque; cloud volumes are wholly in front of it. Draw
        // before window glass, while opaque room/window geometry occludes us.
        Tags { "RenderType"="Transparent" "Queue"="Transparent-50" "IgnoreProjector"="True" }
        Cull Back ZWrite Off ZTest LEqual Blend One OneMinusSrcAlpha
        Pass
        {
            CGPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #include "UnityCG.cginc"
            sampler3D _DensityVolume;
            float4 _VolumeResolution;
            half4 _SunColor, _ShadowColor;
            float _Extinction, _StepCount;
            half _MaasoWorldNightBlend;
            UNITY_INSTANCING_BUFFER_START(CloudProperties)
                UNITY_DEFINE_INSTANCED_PROP(float, _CloudVariant)
                UNITY_DEFINE_INSTANCED_PROP(float, _DensityMultiplier)
            UNITY_INSTANCING_BUFFER_END(CloudProperties)

            struct Input { float4 vertex:POSITION; UNITY_VERTEX_INPUT_INSTANCE_ID };
            struct Output
            {
                float4 position:SV_POSITION;
                float3 worldPosition:TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };
            Output vert(Input v)
            {
                UNITY_SETUP_INSTANCE_ID(v);
                Output o;
                UNITY_INITIALIZE_OUTPUT(Output,o);
                UNITY_TRANSFER_INSTANCE_ID(v,o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.position=UnityObjectToClipPos(v.vertex);
                o.worldPosition=mul(unity_ObjectToWorld,v.vertex).xyz;
                return o;
            }

            half4 SampleCloud(float3 positionOS, float variant)
            {
                float3 texel=saturate(positionOS+.5)*(_VolumeResolution.xyz-1)+.5;
                texel.x+=variant*_VolumeResolution.x;
                float3 dimensions=_VolumeResolution.xyz*float3(_VolumeResolution.w,1,1);
                return tex3Dlod(_DensityVolume,float4(texel/dimensions,0));
            }

            half4 frag(Output i):SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float3 directionWS=normalize(i.worldPosition-_WorldSpaceCameraPos);
                float3 originOS=mul(unity_WorldToObject,float4(_WorldSpaceCameraPos,1)).xyz;
                // Leave directionOS unnormalised: slab distances and integration
                // steps remain in world metres under non-uniform scaling.
                float3 directionOS=mul((float3x3)unity_WorldToObject,directionWS);
                float3 safeDirection=(step(0,directionOS)*2-1)*max(abs(directionOS),1e-6);
                float3 t0=(-.5-originOS)/safeDirection;
                float3 t1=( .5-originOS)/safeDirection;
                float3 nearDistances=min(t0,t1),farDistances=max(t0,t1);
                float start=max(0,max(nearDistances.x,max(nearDistances.y,nearDistances.z)));
                float end=min(farDistances.x,min(farDistances.y,farDistances.z));
                if(end<=start)discard;
                int count=(int)clamp(_StepCount,16,56);
                float stride=(end-start)/count;
                float variant=clamp(floor(UNITY_ACCESS_INSTANCED_PROP(CloudProperties,_CloudVariant)+.5),0,1);
                float multiplier=max(0,UNITY_ACCESS_INSTANCED_PROP(CloudProperties,_DensityMultiplier));
                float transmittance=1;
                half3 radiance=0;
                half night=saturate(_MaasoWorldNightBlend);
                half forwardLight=pow(saturate(dot(directionWS,normalize(float3(-.45,.82,.32)))),8)*.12;
                [loop] for(int sampleIndex=0;sampleIndex<56;sampleIndex++)
                {
                    if(sampleIndex>=count||transmittance<.012)break;
                    float3 p=originOS+directionOS*(start+(sampleIndex+.5)*stride);
                    half4 volume=SampleCloud(p,variant);
                    float density=volume.r*multiplier;
                    if(density>.001)
                    {
                        float alpha=1-exp(-density*_Extinction*stride);
                        half illumination=saturate(volume.g*.94+volume.b*.06);
                        half3 light=lerp(_ShadowColor.rgb*(.78+.22*volume.b),_SunColor.rgb,illumination);
                        light+=_SunColor.rgb*(forwardLight*volume.g);
                        light*=lerp(half3(1,1,1),half3(.12,.17,.25),night);
                        radiance+=transmittance*alpha*light;
                        transmittance*=1-alpha;
                    }
                }
                return half4(radiance,1-transmittance);
            }
            ENDCG
        }
    }
    Fallback Off
}
