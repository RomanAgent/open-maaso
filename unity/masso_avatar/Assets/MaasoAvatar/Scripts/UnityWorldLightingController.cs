using System;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.Avatar
{
    /// <summary>
    /// Smoothly changes the authored avatar scene between its captured daytime
    /// environment and a calibrated night environment. A bundled panoramic
    /// sky is cloned at runtime so day/night transitions never mutate the
    /// imported material asset.
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class UnityWorldLightingController : MonoBehaviour
    {
        [SerializeField] private Camera backgroundCamera;
        [SerializeField] private Light directionalLight;
        [SerializeField, Min(0f)] private float transitionSeconds = 0.45f;
        [SerializeField] private Color nightBackground = new(0.027f, 0.051f, 0.11f, 1f);
        [SerializeField] private Color nightDirectionalColor = new(0.80f, 0.86f, 1f, 1f);
        [SerializeField, Range(0f, 2f)] private float nightDirectionalIntensity = 0.68f;
        // Keep the softer night key in the same front hemisphere as daylight.
        [SerializeField] private Vector3 nightDirectionalEulerAngles = new(32f, 145f, 0f);
        [SerializeField] private Color nightAmbientSky = new(0.25f, 0.28f, 0.36f, 1f);
        [SerializeField] private Color nightAmbientEquator = new(0.18f, 0.20f, 0.27f, 1f);
        [SerializeField] private Color nightAmbientGround = new(0.12f, 0.13f, 0.18f, 1f);
        [SerializeField] private Color nightFogColor = new(0.025f, 0.055f, 0.13f, 1f);
        [SerializeField, Range(0f, 0.1f)] private float nightFogDensity = 0.012f;
        [SerializeField] private Color nightSkyTint = new(0.06f, 0.12f, 0.3f, 1f);
        [SerializeField] private Color nightGroundTint = new(0.012f, 0.02f, 0.06f, 1f);
        [SerializeField, Range(0f, 8f)] private float nightSkyExposure = 0.28f;
        [Header("Desktop companion lighting")]
        [SerializeField] private Color companionDirectionalColor =
            new(1f, 0.98f, 0.95f, 1f);
        [SerializeField, Range(0f, 2f)] private float companionDirectionalIntensity = 1.08f;
        [SerializeField] private Color companionAmbientSky =
            new(0.43f, 0.43f, 0.425f, 1f);
        [SerializeField] private Color companionAmbientEquator =
            new(0.315f, 0.315f, 0.31f, 1f);
        [SerializeField] private Color companionAmbientGround =
            new(0.182f, 0.182f, 0.18f, 1f);
        [SerializeField, Range(0f, 2f)] private float companionAmbientIntensity = 1.02f;
        [SerializeField, Range(0f, 1f)] private float companionReflectionIntensity = 0.08f;
        [SerializeField, Range(0f, 1f)] private float companionShadowStrength = 0.58f;
        [SerializeField, Min(0f)] private float companionShadowBias = 0.05f;
        [SerializeField, Min(0f)] private float companionShadowNormalBias = 0.25f;

        private const string SkyTintProperty = "_SkyTint";
        private const string PanoramicTintProperty = "_Tint";
        private const string GroundColorProperty = "_GroundColor";
        private const string ExposureProperty = "_Exposure";
        private const string HorizonColorProperty = "_HorizonColor";
        private const string ZenithColorProperty = "_ZenithColor";
        private const string DaySkyResourceName = "Maaso_DaySky";
        private static readonly int WorldNightBlendProperty =
            Shader.PropertyToID("_MaasoWorldNightBlend");

        private static readonly Color DaylightBlueFallback =
            new(0.36f, 0.68f, 0.94f, 1f);

        private LightingState dayState;
        private LightingState transitionFrom;
        private LightingState transitionTo;
        private Material originalSkybox;
        private Material runtimeSkybox;
        private float transitionElapsed;
        private bool hasDayState;
        private bool transitioning;
        private CompanionLightingSnapshot companionRestoreState;
        private LightingState companionRestoreTransitionFrom;
        private LightingState companionRestoreTransitionTo;
        private float companionRestoreTransitionElapsed;
        private bool companionRestoreTransitioning;
        private LightingState deferredWorldState;
        private bool hasDeferredWorldState;

        public bool IsNight { get; private set; }
        public bool IsCompanionLightingActive { get; private set; }

        private void Awake()
        {
            EnsureRuntimeSkybox();
            EnsureReferences();
            RestoreNeutralDayEnvironment();
            CaptureDayState();
        }

        private void Update()
        {
            if (!transitioning)
            {
                return;
            }

            transitionElapsed += Time.unscaledDeltaTime;
            float duration = Mathf.Max(0.0001f, transitionSeconds);
            float progress = Mathf.Clamp01(transitionElapsed / duration);
            ApplyState(LightingState.Lerp(transitionFrom, transitionTo, progress));
            if (progress < 1f)
            {
                return;
            }

            transitioning = false;
            DynamicGI.UpdateEnvironment();
        }

        private void OnDestroy()
        {
            ExitCompanionLighting();
            Shader.SetGlobalFloat(WorldNightBlendProperty, 0f);
            if (runtimeSkybox == null)
            {
                return;
            }

            if (RenderSettings.skybox == runtimeSkybox)
            {
                RenderSettings.skybox = originalSkybox;
            }

            if (Application.isPlaying)
            {
                Destroy(runtimeSkybox);
            }
            else
            {
                DestroyImmediate(runtimeSkybox);
            }
        }

        public void SetTimeOfDay(string timeOfDay)
        {
            SetNight(string.Equals(timeOfDay?.Trim(), "night", StringComparison.OrdinalIgnoreCase));
        }

        public void SetNight(bool night)
        {
            EnsureRuntimeSkybox();
            EnsureReferences();
            if (!hasDayState)
            {
                CaptureDayState();
            }

            LightingState requestedWorldState = night
                ? CreateNightState()
                : dayState;
            IsNight = night;
            if (IsCompanionLightingActive)
            {
                deferredWorldState = requestedWorldState;
                hasDeferredWorldState = true;
                return;
            }

            transitionFrom = CaptureCurrentState();
            transitionTo = requestedWorldState;
            transitionElapsed = 0f;
            transitioning = transitionSeconds > 0f;
            if (transitioning)
            {
                return;
            }

            ApplyState(transitionTo);
            DynamicGI.UpdateEnvironment();
        }

        /// <summary>
        /// Applies the softer, lower-exposure lighting used by the transparent
        /// desktop-pet capture. The authored World day/night states remain
        /// untouched and are restored exactly when the capture lease ends.
        /// </summary>
        public void EnterCompanionLighting()
        {
            if (IsCompanionLightingActive)
            {
                return;
            }

            EnsureReferences();
            companionRestoreState =
                CompanionLightingSnapshot.Capture(directionalLight);
            companionRestoreTransitionFrom = transitionFrom;
            companionRestoreTransitionTo = transitionTo;
            companionRestoreTransitionElapsed = transitionElapsed;
            companionRestoreTransitioning = transitioning;
            hasDeferredWorldState = false;
            transitioning = false;
            IsCompanionLightingActive = true;

            RenderSettings.ambientSkyColor = companionAmbientSky;
            RenderSettings.ambientEquatorColor = companionAmbientEquator;
            RenderSettings.ambientGroundColor = companionAmbientGround;
            RenderSettings.ambientIntensity = companionAmbientIntensity;
            RenderSettings.reflectionIntensity = companionReflectionIntensity;
            if (directionalLight != null)
            {
                directionalLight.color = companionDirectionalColor;
                directionalLight.intensity = companionDirectionalIntensity;
                directionalLight.shadows = LightShadows.Soft;
                directionalLight.shadowStrength = companionShadowStrength;
                directionalLight.shadowBias = companionShadowBias;
                directionalLight.shadowNormalBias = companionShadowNormalBias;
            }
            DynamicGI.UpdateEnvironment();
        }

        /// <summary>
        /// Restores every RenderSettings and Light value changed by
        /// <see cref="EnterCompanionLighting"/>. Repeated exits are no-ops.
        /// </summary>
        public void ExitCompanionLighting()
        {
            if (!IsCompanionLightingActive)
            {
                return;
            }

            companionRestoreState.Restore();
            if (hasDeferredWorldState)
            {
                ApplyState(deferredWorldState);
                transitionFrom = deferredWorldState;
                transitionTo = deferredWorldState;
                transitionElapsed = 0f;
                transitioning = false;
            }
            else
            {
                transitionFrom = companionRestoreTransitionFrom;
                transitionTo = companionRestoreTransitionTo;
                transitionElapsed = companionRestoreTransitionElapsed;
                transitioning = companionRestoreTransitioning;
            }
            hasDeferredWorldState = false;
            IsCompanionLightingActive = false;
            DynamicGI.UpdateEnvironment();
        }

        private void EnsureReferences()
        {
            if (backgroundCamera == null)
            {
                backgroundCamera = GetComponent<Camera>() ?? Camera.main;
            }

            if (directionalLight == null)
            {
                directionalLight = RenderSettings.sun;
            }

            if (directionalLight != null)
            {
                ConfigureBackgroundCamera();
                return;
            }

            Light[] lights = FindObjectsByType<Light>(FindObjectsInactive.Exclude, FindObjectsSortMode.None);
            for (int i = 0; i < lights.Length; i++)
            {
                if (lights[i].type == LightType.Directional)
                {
                    directionalLight = lights[i];
                    break;
                }
            }

            ConfigureBackgroundCamera();
        }

        private void ConfigureBackgroundCamera()
        {
            if (backgroundCamera == null)
            {
                return;
            }

            bool hasSky = RenderSettings.skybox != null;
            backgroundCamera.clearFlags = hasSky
                ? CameraClearFlags.Skybox
                : CameraClearFlags.SolidColor;
            backgroundCamera.backgroundColor = DaylightBlueFallback;
        }

        private void EnsureRuntimeSkybox()
        {
            if (runtimeSkybox != null)
            {
                return;
            }

            originalSkybox = RenderSettings.skybox;
            Material bundledSkybox = Resources.Load<Material>(
                DaySkyResourceName);
            Material source = bundledSkybox != null
                ? bundledSkybox
                : originalSkybox;
            if (source == null)
            {
                return;
            }

            runtimeSkybox = new Material(source)
            {
                name = $"{source.name} (Runtime)",
            };
            RenderSettings.skybox = runtimeSkybox;
        }

        private void CaptureDayState()
        {
            dayState = CaptureCurrentState();
            hasDayState = true;
        }

        private void RestoreNeutralDayEnvironment()
        {
            Shader.SetGlobalFloat(WorldNightBlendProperty, 0f);
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor =
                new Color(0.46f, 0.46f, 0.46f, 1f);
            RenderSettings.ambientEquatorColor =
                new Color(0.34f, 0.34f, 0.34f, 1f);
            RenderSettings.ambientGroundColor =
                new Color(0.20f, 0.20f, 0.20f, 1f);
            RenderSettings.ambientIntensity = 0.80f;
            RenderSettings.reflectionIntensity = 0.18f;
            RenderSettings.fog = false;
            RenderSettings.fogColor = new Color(0.72f, 0.73f, 0.74f, 1f);
            RenderSettings.fogDensity = 0f;
            if (runtimeSkybox != null)
            {
                if (runtimeSkybox.HasProperty(ZenithColorProperty))
                {
                    runtimeSkybox.SetColor(
                        ZenithColorProperty,
                        new Color(0.62f, 0.64f, 0.66f, 1f));
                }
                if (runtimeSkybox.HasProperty(HorizonColorProperty))
                {
                    runtimeSkybox.SetColor(
                        HorizonColorProperty,
                        new Color(0.82f, 0.83f, 0.84f, 1f));
                }
                if (runtimeSkybox.HasProperty(PanoramicTintProperty))
                {
                    runtimeSkybox.SetColor(
                        PanoramicTintProperty,
                        Color.white);
                }
                if (runtimeSkybox.HasProperty(ExposureProperty))
                {
                    runtimeSkybox.SetFloat(ExposureProperty, 0.95f);
                }
            }
            if (directionalLight != null)
            {
                RenderSettings.sun = directionalLight;
                // Leave headroom for MToon's additive ambient contribution.
                directionalLight.color = new Color(1f, 0.995f, 0.985f, 1f);
                directionalLight.intensity = 0.90f;
                directionalLight.shadows = LightShadows.Soft;
                directionalLight.shadowStrength = 0.38f;
                directionalLight.shadowBias = 0.025f;
                directionalLight.shadowNormalBias = 0.18f;
                // The front camera views the bundled avatar from +Z.
                // Light from that hemisphere instead of lighting its back.
                directionalLight.transform.rotation =
                    Quaternion.Euler(40f, 145f, 0f);
            }
        }

        private LightingState CaptureCurrentState()
        {
            Material skybox = RenderSettings.skybox;
            return new LightingState(
                backgroundCamera != null ? backgroundCamera.backgroundColor : Color.black,
                directionalLight != null ? directionalLight.color : Color.white,
                directionalLight != null ? directionalLight.intensity : 0f,
                directionalLight != null ? directionalLight.transform.rotation : Quaternion.identity,
                RenderSettings.ambientSkyColor,
                RenderSettings.ambientEquatorColor,
                RenderSettings.ambientGroundColor,
                RenderSettings.fog,
                RenderSettings.fogColor,
                RenderSettings.fogDensity,
                ReadSkyTint(skybox),
                skybox != null && skybox.HasProperty(GroundColorProperty) ? skybox.GetColor(GroundColorProperty) : Color.black,
                skybox != null && skybox.HasProperty(ExposureProperty) ? skybox.GetFloat(ExposureProperty) : 1f,
                Shader.GetGlobalFloat(WorldNightBlendProperty));
        }

        private LightingState CreateNightState()
        {
            return new LightingState(
                nightBackground,
                nightDirectionalColor,
                nightDirectionalIntensity,
                Quaternion.Euler(nightDirectionalEulerAngles),
                nightAmbientSky,
                nightAmbientEquator,
                nightAmbientGround,
                true,
                nightFogColor,
                nightFogDensity,
                nightSkyTint,
                nightGroundTint,
                nightSkyExposure,
                1f);
        }

        private void ApplyState(LightingState state)
        {
            // Baked room radiance deliberately ignores dynamic lights and fog.
            // Give it the same transition as the avatar without changing assets.
            Shader.SetGlobalFloat(WorldNightBlendProperty, state.WorldNightBlend);
            if (backgroundCamera != null)
            {
                backgroundCamera.backgroundColor = state.BackgroundColor;
            }

            if (directionalLight != null)
            {
                directionalLight.color = state.DirectionalColor;
                directionalLight.intensity = state.DirectionalIntensity;
                directionalLight.transform.rotation = state.DirectionalRotation;
            }

            RenderSettings.ambientSkyColor = state.AmbientSky;
            RenderSettings.ambientEquatorColor = state.AmbientEquator;
            RenderSettings.ambientGroundColor = state.AmbientGround;
            RenderSettings.fog = state.Fog;
            RenderSettings.fogColor = state.FogColor;
            RenderSettings.fogDensity = state.FogDensity;

            Material skybox = RenderSettings.skybox;
            if (skybox == null)
            {
                return;
            }

            if (skybox.HasProperty(PanoramicTintProperty))
            {
                skybox.SetColor(PanoramicTintProperty, state.SkyTint);
            }
            else if (skybox.HasProperty(SkyTintProperty))
            {
                skybox.SetColor(SkyTintProperty, state.SkyTint);
            }

            if (skybox.HasProperty(GroundColorProperty))
            {
                skybox.SetColor(GroundColorProperty, state.GroundTint);
            }

            if (skybox.HasProperty(ExposureProperty))
            {
                skybox.SetFloat(ExposureProperty, state.SkyExposure);
            }
        }

        private static Color ReadSkyTint(Material skybox)
        {
            if (skybox == null)
            {
                return Color.black;
            }
            if (skybox.HasProperty(PanoramicTintProperty))
            {
                return skybox.GetColor(PanoramicTintProperty);
            }
            if (skybox.HasProperty(SkyTintProperty))
            {
                return skybox.GetColor(SkyTintProperty);
            }
            return Color.black;
        }

        private readonly struct LightingState
        {
            public LightingState(
                Color backgroundColor,
                Color directionalColor,
                float directionalIntensity,
                Quaternion directionalRotation,
                Color ambientSky,
                Color ambientEquator,
                Color ambientGround,
                bool fog,
                Color fogColor,
                float fogDensity,
                Color skyTint,
                Color groundTint,
                float skyExposure,
                float worldNightBlend)
            {
                BackgroundColor = backgroundColor;
                DirectionalColor = directionalColor;
                DirectionalIntensity = directionalIntensity;
                DirectionalRotation = directionalRotation;
                AmbientSky = ambientSky;
                AmbientEquator = ambientEquator;
                AmbientGround = ambientGround;
                Fog = fog;
                FogColor = fogColor;
                FogDensity = fogDensity;
                SkyTint = skyTint;
                GroundTint = groundTint;
                SkyExposure = skyExposure;
                WorldNightBlend = worldNightBlend;
            }

            public Color BackgroundColor { get; }
            public Color DirectionalColor { get; }
            public float DirectionalIntensity { get; }
            public Quaternion DirectionalRotation { get; }
            public Color AmbientSky { get; }
            public Color AmbientEquator { get; }
            public Color AmbientGround { get; }
            public bool Fog { get; }
            public Color FogColor { get; }
            public float FogDensity { get; }
            public Color SkyTint { get; }
            public Color GroundTint { get; }
            public float SkyExposure { get; }
            public float WorldNightBlend { get; }

            public static LightingState Lerp(LightingState from, LightingState to, float progress)
            {
                return new LightingState(
                    Color.Lerp(from.BackgroundColor, to.BackgroundColor, progress),
                    Color.Lerp(from.DirectionalColor, to.DirectionalColor, progress),
                    Mathf.Lerp(from.DirectionalIntensity, to.DirectionalIntensity, progress),
                    Quaternion.Slerp(from.DirectionalRotation, to.DirectionalRotation, progress),
                    Color.Lerp(from.AmbientSky, to.AmbientSky, progress),
                    Color.Lerp(from.AmbientEquator, to.AmbientEquator, progress),
                    Color.Lerp(from.AmbientGround, to.AmbientGround, progress),
                    progress < 0.5f ? from.Fog : to.Fog,
                    Color.Lerp(from.FogColor, to.FogColor, progress),
                    Mathf.Lerp(from.FogDensity, to.FogDensity, progress),
                    Color.Lerp(from.SkyTint, to.SkyTint, progress),
                    Color.Lerp(from.GroundTint, to.GroundTint, progress),
                    Mathf.Lerp(from.SkyExposure, to.SkyExposure, progress),
                    Mathf.Lerp(from.WorldNightBlend, to.WorldNightBlend, progress));
            }
        }

        private readonly struct CompanionLightingSnapshot
        {
            private CompanionLightingSnapshot(
                Color ambientSky,
                Color ambientEquator,
                Color ambientGround,
                float ambientIntensity,
                float reflectionIntensity,
                Light light,
                Color lightColor,
                float lightIntensity,
                LightShadows lightShadows,
                float shadowStrength,
                float shadowBias,
                float shadowNormalBias)
            {
                AmbientSky = ambientSky;
                AmbientEquator = ambientEquator;
                AmbientGround = ambientGround;
                AmbientIntensity = ambientIntensity;
                ReflectionIntensity = reflectionIntensity;
                Light = light;
                LightColor = lightColor;
                LightIntensity = lightIntensity;
                LightShadows = lightShadows;
                ShadowStrength = shadowStrength;
                ShadowBias = shadowBias;
                ShadowNormalBias = shadowNormalBias;
            }

            private Color AmbientSky { get; }
            private Color AmbientEquator { get; }
            private Color AmbientGround { get; }
            private float AmbientIntensity { get; }
            private float ReflectionIntensity { get; }
            private Light Light { get; }
            private Color LightColor { get; }
            private float LightIntensity { get; }
            private LightShadows LightShadows { get; }
            private float ShadowStrength { get; }
            private float ShadowBias { get; }
            private float ShadowNormalBias { get; }

            public static CompanionLightingSnapshot Capture(Light light)
            {
                return new CompanionLightingSnapshot(
                    RenderSettings.ambientSkyColor,
                    RenderSettings.ambientEquatorColor,
                    RenderSettings.ambientGroundColor,
                    RenderSettings.ambientIntensity,
                    RenderSettings.reflectionIntensity,
                    light,
                    light != null ? light.color : Color.white,
                    light != null ? light.intensity : 0f,
                    light != null ? light.shadows : LightShadows.None,
                    light != null ? light.shadowStrength : 0f,
                    light != null ? light.shadowBias : 0f,
                    light != null ? light.shadowNormalBias : 0f);
            }

            public void Restore()
            {
                RenderSettings.ambientSkyColor = AmbientSky;
                RenderSettings.ambientEquatorColor = AmbientEquator;
                RenderSettings.ambientGroundColor = AmbientGround;
                RenderSettings.ambientIntensity = AmbientIntensity;
                RenderSettings.reflectionIntensity = ReflectionIntensity;
                if (Light == null)
                {
                    return;
                }
                Light.color = LightColor;
                Light.intensity = LightIntensity;
                Light.shadows = LightShadows;
                Light.shadowStrength = ShadowStrength;
                Light.shadowBias = ShadowBias;
                Light.shadowNormalBias = ShadowNormalBias;
            }
        }
    }
}
