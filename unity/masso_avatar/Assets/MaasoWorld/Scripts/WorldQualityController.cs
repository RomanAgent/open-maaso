using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.World
{
    [DisallowMultipleComponent]
    public sealed class WorldQualityController : MonoBehaviour
    {
        private const int FrameWindowSize = 120;
        private const float WarmupSeconds = 5f;
        private const float DegradeCooldownSeconds = 15f;

        private static readonly string[] AndroidHighGpuAllowlist =
        {
            "Adreno 740", "Adreno 750", "Adreno 830",
        };

        private static readonly string[] IosHighGpuAllowlist =
        {
            "Apple A17", "Apple A18", "Apple M1", "Apple M2", "Apple M3", "Apple M4",
        };

        [SerializeField] private WorldQualityProfile mediumProfile;
        [SerializeField] private WorldQualityProfile highProfile;
        [SerializeField] private GameObject[] foliageDensityGroups = Array.Empty<GameObject>();
        [SerializeField] private ParticleSystem[] particles = Array.Empty<ParticleSystem>();
        [SerializeField] private LODGroup[] farDetailLods = Array.Empty<LODGroup>();

        private readonly List<float> frameWindow = new(FrameWindowSize);
        private WorldQualityProfile activeProfile;
        private int consecutiveSlowWindows;
        private float lastDegradeTime = float.NegativeInfinity;
        private float currentResolutionScale = 1f;
        private float currentFoliageDensity = 1f;
        private float currentShadowDistance;
        private bool ownsMediumProfile;
        private bool ownsHighProfile;
        private bool initialized;

        public WorldQualityTier ActiveTier { get; private set; } = WorldQualityTier.Medium;
        public WorldQualityDegradeReason LastDegradeReason { get; private set; }
        public WorldQualityDegradeStep LastDegradationStep { get; private set; }
        public int CurrentDegradationIndex { get; private set; }

        private void Start()
        {
            InitializeForRuntime();
        }

        private void Update()
        {
            RecordFrameTime(Time.unscaledDeltaTime * 1000f, Time.unscaledTime);
        }

        private void OnDestroy()
        {
            if (ownsMediumProfile && mediumProfile != null)
            {
                DestroyRuntimeProfile(mediumProfile);
            }
            if (ownsHighProfile && highProfile != null)
            {
                DestroyRuntimeProfile(highProfile);
            }
        }

        public void InitializeForRuntime()
        {
            if (initialized)
            {
                return;
            }

            if (mediumProfile == null)
            {
                mediumProfile = CreateRuntimeProfile(
                    WorldQualityTier.Medium,
                    30,
                    25f,
                    0.7f,
                    0.9f,
                    2,
                    1f);
                ownsMediumProfile = true;
            }
            if (highProfile == null)
            {
                highProfile = CreateRuntimeProfile(
                    WorldQualityTier.High,
                    60,
                    45f,
                    1f,
                    1f,
                    4,
                    1.4f);
                ownsHighProfile = true;
            }

            initialized = true;
            ApplyTier(SelectDefaultTier(
                Application.platform,
                SystemInfo.systemMemorySize,
                SystemInfo.graphicsDeviceName));
        }

        public void ConfigureProfiles(
            WorldQualityProfile medium,
            WorldQualityProfile high)
        {
            mediumProfile = medium;
            highProfile = high;
        }

        public void ApplyTier(WorldQualityTier tier)
        {
            WorldQualityProfile selected = tier == WorldQualityTier.High
                ? highProfile
                : mediumProfile;
            if (selected == null)
            {
                throw new InvalidOperationException($"World quality profile {tier} is not configured.");
            }

            ActiveTier = tier;
            activeProfile = selected;
            CurrentDegradationIndex = 0;
            LastDegradationStep = WorldQualityDegradeStep.None;
            LastDegradeReason = WorldQualityDegradeReason.None;
            consecutiveSlowWindows = 0;
            frameWindow.Clear();

            currentResolutionScale = selected.ResolutionScale;
            currentFoliageDensity = selected.FoliageDensity;
            currentShadowDistance = selected.ShadowDistance;
            Application.targetFrameRate = selected.TargetFrameRate;
            if (Application.isPlaying)
            {
                QualitySettings.shadows = ShadowQuality.All;
                QualitySettings.shadowResolution = tier == WorldQualityTier.High
                    ? ShadowResolution.High
                    : ShadowResolution.Medium;
                QualitySettings.shadowProjection = ShadowProjection.StableFit;
                QualitySettings.shadowCascades = tier == WorldQualityTier.High ? 4 : 2;
            }
            QualitySettings.shadowDistance = currentShadowDistance;
            QualitySettings.antiAliasing = selected.AntiAliasing;
            QualitySettings.lodBias = selected.FarDetailLodBias;
            ApplyResolutionScale();
            ApplyFoliageDensity();
            SetParticlesEnabled(selected.ParticlesEnabled);
            for (int index = 0; index < farDetailLods.Length; index++)
            {
                farDetailLods[index]?.ForceLOD(-1);
            }
        }

        public bool DegradeOneStep(WorldQualityDegradeReason reason)
        {
            if (activeProfile == null ||
                CurrentDegradationIndex >= activeProfile.DegradationSteps.Count)
            {
                return false;
            }

            WorldQualityDegradeStep step =
                activeProfile.DegradationSteps[CurrentDegradationIndex];
            CurrentDegradationIndex++;
            LastDegradeReason = reason;
            LastDegradationStep = step;
            switch (step)
            {
                case WorldQualityDegradeStep.ResolutionScale:
                    currentResolutionScale = Mathf.Max(0.7f, currentResolutionScale - 0.1f);
                    ApplyResolutionScale();
                    break;
                case WorldQualityDegradeStep.FoliageDensity:
                    currentFoliageDensity = Mathf.Max(0.35f, currentFoliageDensity * 0.7f);
                    ApplyFoliageDensity();
                    break;
                case WorldQualityDegradeStep.ShadowDistance:
                    currentShadowDistance = Mathf.Max(12f, currentShadowDistance * 0.7f);
                    QualitySettings.shadowDistance = currentShadowDistance;
                    break;
                case WorldQualityDegradeStep.Particles:
                    SetParticlesEnabled(false);
                    break;
                case WorldQualityDegradeStep.Antialiasing:
                    QualitySettings.antiAliasing = 0;
                    break;
                case WorldQualityDegradeStep.FarDetailLod:
                    ForceFarDetailLod();
                    break;
            }
            return true;
        }

        public void RecordFrameTime(float milliseconds, float unscaledTime)
        {
            if (activeProfile == null || unscaledTime < WarmupSeconds)
            {
                return;
            }
            frameWindow.Add(Mathf.Max(0f, milliseconds));
            if (frameWindow.Count < FrameWindowSize)
            {
                return;
            }

            frameWindow.Sort();
            int percentileIndex = Mathf.Clamp(
                Mathf.CeilToInt(frameWindow.Count * 0.95f) - 1,
                0,
                frameWindow.Count - 1);
            float p95 = frameWindow[percentileIndex];
            frameWindow.Clear();
            float threshold = ActiveTier == WorldQualityTier.High ? 20f : 36f;
            consecutiveSlowWindows = p95 > threshold
                ? consecutiveSlowWindows + 1
                : 0;
            if (consecutiveSlowWindows < 3 ||
                unscaledTime - lastDegradeTime < DegradeCooldownSeconds)
            {
                return;
            }
            if (DegradeOneStep(WorldQualityDegradeReason.FrameTime))
            {
                lastDegradeTime = unscaledTime;
            }
            consecutiveSlowWindows = 0;
        }

        public static WorldQualityTier SelectDefaultTier(
            RuntimePlatform platform,
            int systemMemoryMegabytes,
            string graphicsDeviceName)
        {
            if (platform == RuntimePlatform.Android)
            {
                return systemMemoryMegabytes >= 8192 &&
                    MatchesAllowlist(graphicsDeviceName, AndroidHighGpuAllowlist)
                    ? WorldQualityTier.High
                    : WorldQualityTier.Medium;
            }
            if (platform == RuntimePlatform.IPhonePlayer)
            {
                return MatchesAllowlist(graphicsDeviceName, IosHighGpuAllowlist)
                    ? WorldQualityTier.High
                    : WorldQualityTier.Medium;
            }
            return WorldQualityTier.Medium;
        }

        private static bool MatchesAllowlist(string value, IReadOnlyList<string> allowlist)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return false;
            }
            for (int index = 0; index < allowlist.Count; index++)
            {
                if (value.IndexOf(allowlist[index], StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }
            }
            return false;
        }

        private static WorldQualityProfile CreateRuntimeProfile(
            WorldQualityTier tier,
            int frameRate,
            float shadowDistance,
            float foliageDensity,
            float resolutionScale,
            int antialiasing,
            float lodBias)
        {
            WorldQualityProfile profile =
                ScriptableObject.CreateInstance<WorldQualityProfile>();
            profile.hideFlags = HideFlags.HideAndDontSave;
            profile.Configure(
                tier,
                frameRate,
                shadowDistance,
                foliageDensity,
                resolutionScale,
                true,
                antialiasing,
                lodBias,
                new[]
                {
                    WorldQualityDegradeStep.ResolutionScale,
                    WorldQualityDegradeStep.FoliageDensity,
                    WorldQualityDegradeStep.ShadowDistance,
                    WorldQualityDegradeStep.Particles,
                    WorldQualityDegradeStep.Antialiasing,
                    WorldQualityDegradeStep.FarDetailLod,
                });
            return profile;
        }

        private static void DestroyRuntimeProfile(WorldQualityProfile profile)
        {
            if (Application.isPlaying)
            {
                Destroy(profile);
            }
            else
            {
                DestroyImmediate(profile);
            }
        }

        private void ApplyResolutionScale()
        {
            ScalableBufferManager.ResizeBuffers(
                currentResolutionScale,
                currentResolutionScale);
        }

        private void ApplyFoliageDensity()
        {
            int visibleCount = Mathf.CeilToInt(
                foliageDensityGroups.Length * currentFoliageDensity);
            for (int index = 0; index < foliageDensityGroups.Length; index++)
            {
                if (foliageDensityGroups[index] != null)
                {
                    foliageDensityGroups[index].SetActive(index < visibleCount);
                }
            }
        }

        private void SetParticlesEnabled(bool enabled)
        {
            for (int index = 0; index < particles.Length; index++)
            {
                ParticleSystem system = particles[index];
                if (system == null)
                {
                    continue;
                }
                ParticleSystem.EmissionModule emission = system.emission;
                emission.enabled = enabled;
            }
        }

        private void ForceFarDetailLod()
        {
            for (int index = 0; index < farDetailLods.Length; index++)
            {
                LODGroup group = farDetailLods[index];
                if (group == null || group.lodCount == 0)
                {
                    continue;
                }
                group.ForceLOD(group.lodCount - 1);
            }
        }
    }
}
