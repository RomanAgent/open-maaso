using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class WorldQualityControllerTests
{
    private const string ControllerTypeName =
        "Maaso.World.WorldQualityController, Assembly-CSharp";
    private const string ProfileTypeName =
        "Maaso.World.WorldQualityProfile, Assembly-CSharp";
    private const string TierTypeName =
        "Maaso.World.WorldQualityTier, Assembly-CSharp";
    private const string ReasonTypeName =
        "Maaso.World.WorldQualityDegradeReason, Assembly-CSharp";
    private const string StepTypeName =
        "Maaso.World.WorldQualityDegradeStep, Assembly-CSharp";

    [Test]
    public void MediumAndHighProfilesApplyExpectedMobileBudgets()
    {
        using var fixture = QualityFixture.Create();

        fixture.ApplyTier("Medium");
        Assert.That(fixture.ActiveTier, Is.EqualTo("Medium"));
        Assert.That(Application.targetFrameRate, Is.EqualTo(30));
        Assert.That(QualitySettings.shadowDistance, Is.EqualTo(25f).Within(0.001f));

        fixture.ApplyTier("High");
        Assert.That(fixture.ActiveTier, Is.EqualTo("High"));
        Assert.That(Application.targetFrameRate, Is.EqualTo(60));
        Assert.That(QualitySettings.shadowDistance, Is.EqualTo(45f).Within(0.001f));
    }

    [Test]
    public void DegradationOrderIsFixedAndOnlyTouchesEnvironmentReferences()
    {
        using var fixture = QualityFixture.Create();
        var nearbyAgent = new GameObject("NearbyRealAgent");
        var ownerAgent = new GameObject("OwnerAgent");
        try
        {
            fixture.ApplyTier("High");
            string[] expected =
            {
                "ResolutionScale",
                "FoliageDensity",
                "ShadowDistance",
                "Particles",
                "Antialiasing",
                "FarDetailLod",
            };
            foreach (string step in expected)
            {
                Assert.That(fixture.Degrade("FrameTime"), Is.True, step);
                Assert.That(fixture.LastDegradationStep, Is.EqualTo(step));
                Assert.That(nearbyAgent.activeSelf, Is.True);
                Assert.That(ownerAgent.activeSelf, Is.True);
            }
            Assert.That(fixture.Degrade("FrameTime"), Is.False);
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(nearbyAgent);
            UnityEngine.Object.DestroyImmediate(ownerAgent);
        }
    }

    [Test]
    public void DeviceSelectionRequiresReviewedGpuAndEightGigabytes()
    {
        Type controllerType = Type.GetType(ControllerTypeName);
        Assert.That(controllerType, Is.Not.Null);
        MethodInfo select = controllerType.GetMethod(
            "SelectDefaultTier",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(select, Is.Not.Null);

        Assert.That(
            select.Invoke(null, new object[] { RuntimePlatform.Android, 4096, "Adreno 750" })
                ?.ToString(),
            Is.EqualTo("Medium"));
        Assert.That(
            select.Invoke(null, new object[] { RuntimePlatform.Android, 8192, "Adreno 750" })
                ?.ToString(),
            Is.EqualTo("High"));
        Assert.That(
            select.Invoke(null, new object[] { RuntimePlatform.Android, 12288, "Mali-G76" })
                ?.ToString(),
            Is.EqualTo("Medium"));
        Assert.That(
            select.Invoke(null, new object[] { RuntimePlatform.IPhonePlayer, 6144, "Apple A17 GPU" })
                ?.ToString(),
            Is.EqualTo("High"));
    }

    [Test]
    public void ThreeSlowP95WindowsDegradeOnceAndNeverAutoUpgrade()
    {
        using var fixture = QualityFixture.Create();
        fixture.ApplyTier("Medium");

        float time = 5f;
        for (int frame = 0; frame < 360; frame++)
        {
            fixture.RecordFrame(40f, time);
            time += 0.04f;
        }
        Assert.That(fixture.CurrentDegradationIndex, Is.EqualTo(1));
        Assert.That(fixture.LastDegradationStep, Is.EqualTo("ResolutionScale"));

        for (int frame = 0; frame < 360; frame++)
        {
            fixture.RecordFrame(16f, time);
            time += 0.016f;
        }
        Assert.That(fixture.CurrentDegradationIndex, Is.EqualTo(1));
    }

    private sealed class QualityFixture : IDisposable
    {
        private readonly int previousTargetFrameRate;
        private readonly ShadowQuality previousShadows;
        private readonly ShadowResolution previousShadowResolution;
        private readonly ShadowProjection previousShadowProjection;
        private readonly int previousShadowCascades;
        private readonly float previousShadowDistance;
        private readonly int previousAntialiasing;
        private readonly float previousLodBias;
        private readonly float previousWidthScale;
        private readonly float previousHeightScale;
        private readonly GameObject root;

        private QualityFixture(
            GameObject root,
            Component controller,
            int previousTargetFrameRate,
            ShadowQuality previousShadows,
            ShadowResolution previousShadowResolution,
            ShadowProjection previousShadowProjection,
            int previousShadowCascades,
            float previousShadowDistance,
            int previousAntialiasing,
            float previousLodBias,
            float previousWidthScale,
            float previousHeightScale)
        {
            this.root = root;
            Controller = controller;
            this.previousTargetFrameRate = previousTargetFrameRate;
            this.previousShadows = previousShadows;
            this.previousShadowResolution = previousShadowResolution;
            this.previousShadowProjection = previousShadowProjection;
            this.previousShadowCascades = previousShadowCascades;
            this.previousShadowDistance = previousShadowDistance;
            this.previousAntialiasing = previousAntialiasing;
            this.previousLodBias = previousLodBias;
            this.previousWidthScale = previousWidthScale;
            this.previousHeightScale = previousHeightScale;
        }

        public Component Controller { get; }
        public string ActiveTier => Property("ActiveTier").ToString();
        public string LastDegradationStep => Property("LastDegradationStep").ToString();
        public int CurrentDegradationIndex => (int)Property("CurrentDegradationIndex");

        public static QualityFixture Create()
        {
            Type controllerType = Type.GetType(ControllerTypeName);
            Assert.That(controllerType, Is.Not.Null);
            var root = new GameObject("QualityFixture");
            Component controller = root.AddComponent(controllerType);
            SetField(controller, "mediumProfile", CreateProfile("Medium", 30, 25f, 0.7f));
            SetField(controller, "highProfile", CreateProfile("High", 60, 45f, 1f));

            var foliage = new GameObject[4];
            for (int index = 0; index < foliage.Length; index++)
            {
                foliage[index] = new GameObject("FoliageDensity-" + index);
                foliage[index].transform.SetParent(root.transform, false);
            }
            SetField(controller, "foliageDensityGroups", foliage);
            ParticleSystem particles = root.AddComponent<ParticleSystem>();
            SetField(controller, "particles", new[] { particles });

            return new QualityFixture(
                root,
                controller,
                Application.targetFrameRate,
                QualitySettings.shadows,
                QualitySettings.shadowResolution,
                QualitySettings.shadowProjection,
                QualitySettings.shadowCascades,
                QualitySettings.shadowDistance,
                QualitySettings.antiAliasing,
                QualitySettings.lodBias,
                ScalableBufferManager.widthScaleFactor,
                ScalableBufferManager.heightScaleFactor);
        }

        public void ApplyTier(string tier)
        {
            Controller.GetType().GetMethod("ApplyTier")?.Invoke(
                Controller,
                new[] { Enum.Parse(Type.GetType(TierTypeName), tier) });
        }

        public bool Degrade(string reason)
        {
            return (bool)Controller.GetType().GetMethod("DegradeOneStep")?.Invoke(
                Controller,
                new[] { Enum.Parse(Type.GetType(ReasonTypeName), reason) });
        }

        public void RecordFrame(float milliseconds, float time)
        {
            Controller.GetType().GetMethod("RecordFrameTime")?.Invoke(
                Controller,
                new object[] { milliseconds, time });
        }

        public void Dispose()
        {
            Application.targetFrameRate = previousTargetFrameRate;
            QualitySettings.shadows = previousShadows;
            QualitySettings.shadowResolution = previousShadowResolution;
            QualitySettings.shadowProjection = previousShadowProjection;
            QualitySettings.shadowCascades = previousShadowCascades;
            QualitySettings.shadowDistance = previousShadowDistance;
            QualitySettings.antiAliasing = previousAntialiasing;
            QualitySettings.lodBias = previousLodBias;
            ScalableBufferManager.ResizeBuffers(previousWidthScale, previousHeightScale);
            UnityEngine.Object.DestroyImmediate(root);
        }

        private object Property(string name)
        {
            PropertyInfo property = Controller.GetType().GetProperty(name);
            Assert.That(property, Is.Not.Null, name);
            return property.GetValue(Controller);
        }

        private static ScriptableObject CreateProfile(
            string tier,
            int targetFrameRate,
            float shadowDistance,
            float foliageDensity)
        {
            Type profileType = Type.GetType(ProfileTypeName);
            Type tierType = Type.GetType(TierTypeName);
            Type stepType = Type.GetType(StepTypeName);
            Assert.That(profileType, Is.Not.Null);
            Assert.That(tierType, Is.Not.Null);
            Assert.That(stepType, Is.Not.Null);
            ScriptableObject profile = ScriptableObject.CreateInstance(profileType);
            SetField(profile, "tier", Enum.Parse(tierType, tier));
            SetField(profile, "targetFrameRate", targetFrameRate);
            SetField(profile, "shadowDistance", shadowDistance);
            SetField(profile, "foliageDensity", foliageDensity);
            SetField(profile, "resolutionScale", tier == "High" ? 1f : 0.9f);
            SetField(profile, "particlesEnabled", true);
            SetField(profile, "antiAliasing", tier == "High" ? 4 : 2);
            SetField(profile, "farDetailLodBias", tier == "High" ? 1.4f : 1f);

            string[] names =
            {
                "ResolutionScale", "FoliageDensity", "ShadowDistance",
                "Particles", "Antialiasing", "FarDetailLod",
            };
            Array steps = Array.CreateInstance(stepType, names.Length);
            for (int index = 0; index < names.Length; index++)
            {
                steps.SetValue(Enum.Parse(stepType, names[index]), index);
            }
            SetField(profile, "degradationSteps", steps);
            return profile;
        }

        private static void SetField(object target, string name, object value)
        {
            FieldInfo field = target.GetType().GetField(
                name,
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(field, Is.Not.Null, name);
            field.SetValue(target, value);
        }
    }
}
