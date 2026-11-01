using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.World
{
    public enum WorldQualityTier
    {
        Medium,
        High,
    }

    public enum WorldQualityDegradeReason
    {
        None,
        FrameTime,
        MemoryPressure,
        Thermal,
    }

    public enum WorldQualityDegradeStep
    {
        None,
        ResolutionScale,
        FoliageDensity,
        ShadowDistance,
        Particles,
        Antialiasing,
        FarDetailLod,
    }

    [CreateAssetMenu(
        fileName = "WorldQualityProfile",
        menuName = "Maaso/World/Quality Profile")]
    public sealed class WorldQualityProfile : ScriptableObject
    {
        [SerializeField] private WorldQualityTier tier = WorldQualityTier.Medium;
        [SerializeField, Min(1)] private int targetFrameRate = 30;
        [SerializeField, Min(0f)] private float shadowDistance = 25f;
        [SerializeField, Range(0f, 1f)] private float foliageDensity = 0.7f;
        [SerializeField, Range(0.5f, 1f)] private float resolutionScale = 0.9f;
        [SerializeField] private bool particlesEnabled = true;
        [SerializeField] private int antiAliasing = 2;
        [SerializeField, Min(0.1f)] private float farDetailLodBias = 1f;
        [SerializeField] private WorldQualityDegradeStep[] degradationSteps =
        {
            WorldQualityDegradeStep.ResolutionScale,
            WorldQualityDegradeStep.FoliageDensity,
            WorldQualityDegradeStep.ShadowDistance,
            WorldQualityDegradeStep.Particles,
            WorldQualityDegradeStep.Antialiasing,
            WorldQualityDegradeStep.FarDetailLod,
        };

        public WorldQualityTier Tier => tier;
        public int TargetFrameRate => targetFrameRate;
        public float ShadowDistance => shadowDistance;
        public float FoliageDensity => foliageDensity;
        public float ResolutionScale => resolutionScale;
        public bool ParticlesEnabled => particlesEnabled;
        public int AntiAliasing => antiAliasing;
        public float FarDetailLodBias => farDetailLodBias;
        public IReadOnlyList<WorldQualityDegradeStep> DegradationSteps => degradationSteps;

        public void Configure(
            WorldQualityTier qualityTier,
            int frameRate,
            float shadows,
            float density,
            float scale,
            bool enableParticles,
            int antialiasing,
            float lodBias,
            WorldQualityDegradeStep[] steps)
        {
            tier = qualityTier;
            targetFrameRate = Mathf.Max(1, frameRate);
            shadowDistance = Mathf.Max(0f, shadows);
            foliageDensity = Mathf.Clamp01(density);
            resolutionScale = Mathf.Clamp(scale, 0.5f, 1f);
            particlesEnabled = enableParticles;
            antiAliasing = antialiasing;
            farDetailLodBias = Mathf.Max(0.1f, lodBias);
            degradationSteps = steps == null
                ? Array.Empty<WorldQualityDegradeStep>()
                : (WorldQualityDegradeStep[])steps.Clone();
        }
    }
}
