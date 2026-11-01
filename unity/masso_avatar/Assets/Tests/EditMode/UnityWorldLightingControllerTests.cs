using System;
using System.Reflection;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;

public sealed class UnityWorldLightingControllerTests
{
    private const string ControllerTypeName = "Maaso.Avatar.UnityWorldLightingController, Assembly-CSharp";
    private const string ReceiverTypeName = "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp";

    [Test]
    public void NightKeepsTheAvatarFrontLitAndDimsTheBakedRoom()
    {
        using var fixture = LightingFixture.Create();
        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"), Is.Zero);

        fixture.SetTimeOfDay("night");

        float frontLight = Vector3.Dot(Vector3.forward,
            -fixture.DirectionalLight.transform.forward);
        Assert.That(frontLight, Is.GreaterThan(0.5f),
            "Night must light the avatar's front instead of leaving it in silhouette.");
        Assert.That(frontLight * fixture.DirectionalLight.intensity *
            fixture.DirectionalLight.color.grayscale, Is.GreaterThan(0.3f),
            "The night key must retain enough front illumination to show skin and clothing.");
        Assert.That(RenderSettings.ambientEquatorColor.grayscale, Is.GreaterThan(0.18f));
        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"), Is.EqualTo(1f));

        fixture.SetTimeOfDay("day");

        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"), Is.Zero);
    }

    [Test]
    public void ShippedCompanionSceneAlsoKeepsTheNightKeyOnTheAvatarFront()
    {
        var scene = EditorSceneManager.OpenPreviewScene(
            "Assets/MaasoAvatar/Scenes/Companion.unity");
        try
        {
            Type controllerType = Type.GetType(ControllerTypeName, true);
            Component controller = null;
            foreach (GameObject root in scene.GetRootGameObjects())
            {
                controller = root.GetComponentInChildren(controllerType, true);
                if (controller != null) break;
            }
            Assert.That(controller, Is.Not.Null);
            var serialized = new UnityEditor.SerializedObject(controller);
            Vector3 angles = serialized.FindProperty("nightDirectionalEulerAngles").vector3Value;
            float intensity = serialized.FindProperty("nightDirectionalIntensity").floatValue;
            Color color = serialized.FindProperty("nightDirectionalColor").colorValue;
            float frontLight = Vector3.Dot(Vector3.forward,
                -(Quaternion.Euler(angles) * Vector3.forward));
            Assert.That(frontLight * intensity * color.grayscale, Is.GreaterThan(0.3f),
                "Shipped scene values override C# defaults and must retain readable night lighting too.");
        }
        finally
        {
            EditorSceneManager.ClosePreviewScene(scene);
        }
    }

    [Test]
    public void BakedRoomThemeFollowsInterruptedLightingTransitions()
    {
        using var fixture = LightingFixture.Create();
        SetField(fixture.Controller, "transitionSeconds", 1000f);
        fixture.SetTimeOfDay("night");
        SetField(fixture.Controller, "transitionElapsed", 500f);
        fixture.UpdateLighting();
        float halfway = Shader.GetGlobalFloat("_MaasoWorldNightBlend");
        Assert.That(halfway, Is.InRange(0.49f, 0.51f));

        fixture.SetTimeOfDay("day");
        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"),
            Is.EqualTo(halfway), "Reversing the theme must not flash the baked room.");
        SetField(fixture.Controller, "transitionElapsed", 1000f);
        fixture.UpdateLighting();
        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"), Is.Zero);
    }

    [Test]
    public void BakedRoomThemeDoesNotLeakAfterLightingControllerIsDestroyed()
    {
        using var fixture = LightingFixture.Create();
        fixture.SetTimeOfDay("night");

        // Like Awake in this fixture, the ordinary runtime MonoBehaviour's
        // teardown callback must be driven explicitly outside PlayMode.
        fixture.Controller.GetType().GetMethod("OnDestroy",
            BindingFlags.NonPublic | BindingFlags.Instance)
            .Invoke(fixture.Controller, Array.Empty<object>());
        UnityEngine.Object.DestroyImmediate(fixture.Controller);

        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"), Is.Zero);
    }

    [Test]
    public void NightCommandChangesWorldAndRestoresCapturedDayBaseline()
    {
        using var fixture = LightingFixture.Create();

        fixture.SetTimeOfDay("night");

        Assert.That(fixture.IsNight, Is.True);
        Assert.That(fixture.Camera.backgroundColor.b, Is.GreaterThan(fixture.Camera.backgroundColor.r));
        Assert.That(fixture.DirectionalLight.intensity, Is.LessThan(fixture.DayLightIntensity));
        Assert.That(RenderSettings.ambientSkyColor.b, Is.GreaterThan(RenderSettings.ambientSkyColor.r));

        fixture.SetTimeOfDay("day");

        Assert.That(fixture.IsNight, Is.False);
        Assert.That(fixture.Camera.backgroundColor, Is.EqualTo(fixture.DayBackground));
        Assert.That(fixture.DirectionalLight.intensity, Is.EqualTo(fixture.DayLightIntensity));
        Assert.That(RenderSettings.ambientSkyColor, Is.EqualTo(fixture.DayAmbientSky));
    }

    [Test]
    public void ReceiverForwardsWorldTimeOfDayCommandToLightingController()
    {
        using var fixture = LightingFixture.Create();
        Type receiverType = Type.GetType(ReceiverTypeName);
        Assert.That(receiverType, Is.Not.Null, "Unity avatar command receiver should exist.");
        Component receiver = fixture.Camera.gameObject.AddComponent(receiverType);
        SetField(receiver, "worldLighting", fixture.Controller);

        const string payload = "{\"method\":\"setWorldTimeOfDay\",\"json\":\"{\\\"timeOfDay\\\":\\\"night\\\"}\"}";
        receiverType.GetMethod("OnFlutterCommand")?.Invoke(receiver, new object[] { payload });

        Assert.That(fixture.IsNight, Is.True);
    }

    [Test]
    public void MobileDaySkyInstallsAtRuntimeAndRestoresDayTintAndExposure()
    {
        using var fixture = LightingFixture.Create();

        Assert.That(fixture.Camera.clearFlags, Is.EqualTo(CameraClearFlags.Skybox));
        Assert.That(fixture.Camera.backgroundColor.b, Is.GreaterThan(
            fixture.Camera.backgroundColor.r));
        Material skybox = RenderSettings.skybox;
        Assert.That(skybox, Is.Not.Null);
        Assert.That(skybox.shader.name, Is.EqualTo("Maaso/Mobile Day Sky"));
        Assert.That(
            skybox.HasProperty("_Tex"),
            Is.False,
            "The runtime day sky must not depend on an HDR cubemap that can be " +
            "compressed into a white ASTC texture on mobile.");
        Color dayTint = skybox.GetColor("_Tint");
        float dayExposure = skybox.GetFloat("_Exposure");

        fixture.SetTimeOfDay("night");

        Assert.That(
            RenderSettings.skybox.GetColor("_Tint").grayscale,
            Is.LessThan(dayTint.grayscale));
        Assert.That(
            RenderSettings.skybox.GetFloat("_Exposure"),
            Is.LessThan(dayExposure));

        fixture.SetTimeOfDay("day");

        Color restoredTint = RenderSettings.skybox.GetColor("_Tint");
        Assert.That(
            restoredTint.r,
            Is.EqualTo(dayTint.r).Within(0.001f));
        Assert.That(
            restoredTint.g,
            Is.EqualTo(dayTint.g).Within(0.001f));
        Assert.That(
            restoredTint.b,
            Is.EqualTo(dayTint.b).Within(0.001f));
        Assert.That(
            RenderSettings.skybox.GetFloat("_Exposure"),
            Is.EqualTo(dayExposure).Within(0.001f));
    }

    [Test]
    public void DayEnvironmentRestoresNeutralAmbientAndFogPalette()
    {
        using var fixture = LightingFixture.Create();

        Assert.That(RenderSettings.ambientMode, Is.EqualTo(AmbientMode.Trilight));
        AssertColor(
            RenderSettings.ambientSkyColor,
            new Color(0.46f, 0.46f, 0.46f, 1f));
        AssertColor(
            RenderSettings.ambientEquatorColor,
            new Color(0.34f, 0.34f, 0.34f, 1f));
        AssertColor(
            RenderSettings.ambientGroundColor,
            new Color(0.20f, 0.20f, 0.20f, 1f));
        Assert.That(RenderSettings.ambientIntensity, Is.EqualTo(0.80f).Within(0.0001f));
        Assert.That(RenderSettings.reflectionIntensity, Is.EqualTo(0.18f).Within(0.0001f));
        Assert.That(RenderSettings.fog, Is.False);
        Assert.That(RenderSettings.fogDensity, Is.Zero.Within(0.0001f));
        AssertColor(
            fixture.DirectionalLight.color,
            new Color(1f, 0.995f, 0.985f, 1f));
        Assert.That(fixture.DirectionalLight.intensity, Is.EqualTo(0.90f).Within(0.0001f));
        Assert.That(fixture.DirectionalLight.shadows, Is.EqualTo(LightShadows.Soft));
        Assert.That(fixture.DirectionalLight.shadowStrength, Is.EqualTo(0.38f).Within(0.0001f));
        Assert.That(
            Quaternion.Angle(
                fixture.DirectionalLight.transform.rotation,
                Quaternion.Euler(40f, 145f, 0f)),
            Is.LessThan(0.01f));
        Assert.That(
            Vector3.Dot(Vector3.forward, -fixture.DirectionalLight.transform.forward),
            Is.GreaterThan(0.5f),
            "The day key must light the avatar's front rather than its back.");
        Assert.That(RenderSettings.skybox.GetFloat("_Exposure"), Is.EqualTo(0.95f).Within(0.0001f));
    }

    [Test]
    public void MobileMediumQualityAllowsAuthoredSoftShadows()
    {
        int previousQuality = QualitySettings.GetQualityLevel();
        try
        {
            int mediumQuality = Array.IndexOf(QualitySettings.names, "Medium");
            Assert.That(mediumQuality, Is.GreaterThanOrEqualTo(0));
            QualitySettings.SetQualityLevel(mediumQuality, true);

            Assert.That(
                QualitySettings.shadows,
                Is.EqualTo(ShadowQuality.All),
                "The mobile Medium profile must not force authored soft shadows to hard shadows.");
        }
        finally
        {
            QualitySettings.SetQualityLevel(previousQuality, true);
        }
    }

    [Test]
    public void DesktopCompanionLightingUsesCalibratedSoftPalette()
    {
        using var fixture = LightingFixture.Create();
        Color dayAmbientSky = RenderSettings.ambientSkyColor;
        Color dayAmbientEquator = RenderSettings.ambientEquatorColor;
        Color dayAmbientGround = RenderSettings.ambientGroundColor;
        float dayAmbientIntensity = RenderSettings.ambientIntensity;
        float dayReflectionIntensity = RenderSettings.reflectionIntensity;

        fixture.EnterCompanionLighting();

        Assert.That(fixture.IsCompanionLightingActive, Is.True);
        AssertColor(
            RenderSettings.ambientSkyColor,
            new Color(0.43f, 0.43f, 0.425f, 1f));
        AssertColor(
            RenderSettings.ambientEquatorColor,
            new Color(0.315f, 0.315f, 0.31f, 1f));
        AssertColor(
            RenderSettings.ambientGroundColor,
            new Color(0.182f, 0.182f, 0.18f, 1f));
        Assert.That(
            RenderSettings.ambientIntensity,
            Is.EqualTo(1.02f).Within(0.0001f));
        Assert.That(
            RenderSettings.reflectionIntensity,
            Is.EqualTo(0.08f).Within(0.0001f));
        AssertColor(
            fixture.DirectionalLight.color,
            new Color(1f, 0.98f, 0.95f, 1f));
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(1.08f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.shadows,
            Is.EqualTo(LightShadows.Soft));
        Assert.That(
            fixture.DirectionalLight.shadowStrength,
            Is.EqualTo(0.58f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.shadowBias,
            Is.EqualTo(0.05f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.shadowNormalBias,
            Is.EqualTo(0.25f).Within(0.0001f));
        Assert.That(
            RenderSettings.ambientSkyColor.grayscale,
            Is.LessThan(dayAmbientSky.grayscale));
        Assert.That(
            RenderSettings.ambientEquatorColor.grayscale,
            Is.LessThan(dayAmbientEquator.grayscale));
        Assert.That(
            RenderSettings.ambientGroundColor.grayscale,
            Is.LessThan(dayAmbientGround.grayscale));
        Assert.That(
            RenderSettings.ambientIntensity,
            Is.InRange(dayAmbientIntensity, dayAmbientIntensity + 0.25f),
            "Reference matching may use bounded neutral fill above World day.");
        Assert.That(
            RenderSettings.reflectionIntensity,
            Is.LessThan(dayReflectionIntensity));
        float companionKeyLightEnergy =
            RenderSettings.ambientSkyColor.grayscale *
                RenderSettings.ambientIntensity +
            fixture.DirectionalLight.intensity;
        Assert.That(
            companionKeyLightEnergy,
            Is.EqualTo(1.518f).Within(0.001f));
        Assert.That(
            companionKeyLightEnergy,
            Is.LessThan(1.52f),
            "Reference matching must preserve a bounded highlight headroom.");

        fixture.ExitCompanionLighting();
    }

    [Test]
    public void DesktopCompanionLightingIsIdempotentAndRestoresExactState()
    {
        using var fixture = LightingFixture.Create();
        var expectedAmbientSky = new Color(0.27f, 0.31f, 0.35f, 1f);
        var expectedAmbientEquator = new Color(0.19f, 0.23f, 0.29f, 1f);
        var expectedAmbientGround = new Color(0.08f, 0.11f, 0.17f, 1f);
        var expectedLightColor = new Color(0.83f, 0.88f, 0.97f, 1f);
        RenderSettings.ambientSkyColor = expectedAmbientSky;
        RenderSettings.ambientEquatorColor = expectedAmbientEquator;
        RenderSettings.ambientGroundColor = expectedAmbientGround;
        RenderSettings.ambientIntensity = 0.63f;
        RenderSettings.reflectionIntensity = 0.27f;
        fixture.DirectionalLight.color = expectedLightColor;
        fixture.DirectionalLight.intensity = 0.84f;
        fixture.DirectionalLight.shadows = LightShadows.Hard;
        fixture.DirectionalLight.shadowStrength = 0.43f;
        fixture.DirectionalLight.shadowBias = 0.08f;
        fixture.DirectionalLight.shadowNormalBias = 0.37f;

        fixture.EnterCompanionLighting();
        fixture.EnterCompanionLighting();
        fixture.ExitCompanionLighting();
        fixture.ExitCompanionLighting();

        Assert.That(fixture.IsCompanionLightingActive, Is.False);
        AssertColor(RenderSettings.ambientSkyColor, expectedAmbientSky);
        AssertColor(RenderSettings.ambientEquatorColor, expectedAmbientEquator);
        AssertColor(RenderSettings.ambientGroundColor, expectedAmbientGround);
        Assert.That(
            RenderSettings.ambientIntensity,
            Is.EqualTo(0.63f).Within(0.0001f));
        Assert.That(
            RenderSettings.reflectionIntensity,
            Is.EqualTo(0.27f).Within(0.0001f));
        AssertColor(fixture.DirectionalLight.color, expectedLightColor);
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(0.84f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.shadows,
            Is.EqualTo(LightShadows.Hard));
        Assert.That(
            fixture.DirectionalLight.shadowStrength,
            Is.EqualTo(0.43f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.shadowBias,
            Is.EqualTo(0.08f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.shadowNormalBias,
            Is.EqualTo(0.37f).Within(0.0001f));
    }

    [Test]
    public void DesktopCompanionCycleDoesNotReplaceWorldNightOrDayState()
    {
        using var fixture = LightingFixture.Create();

        fixture.SetTimeOfDay("night");
        Color nightAmbientSky = RenderSettings.ambientSkyColor;
        float nightLightIntensity = fixture.DirectionalLight.intensity;
        fixture.EnterCompanionLighting();
        fixture.ExitCompanionLighting();

        Assert.That(fixture.IsNight, Is.True);
        AssertColor(RenderSettings.ambientSkyColor, nightAmbientSky);
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(nightLightIntensity).Within(0.0001f));

        fixture.SetTimeOfDay("day");

        Assert.That(fixture.IsNight, Is.False);
        AssertColor(RenderSettings.ambientSkyColor, fixture.DayAmbientSky);
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(fixture.DayLightIntensity).Within(0.0001f));
    }

    [Test]
    public void DesktopCompanionLightingDefersNightUntilExit()
    {
        using var fixture = LightingFixture.Create();

        fixture.EnterCompanionLighting();
        fixture.SetTimeOfDay("night");
        fixture.UpdateLighting();
        fixture.UpdateLighting();

        Assert.That(fixture.IsCompanionLightingActive, Is.True);
        Assert.That(fixture.IsNight, Is.True);
        AssertColor(
            RenderSettings.ambientSkyColor,
            new Color(0.43f, 0.43f, 0.425f, 1f));
        Assert.That(
            RenderSettings.ambientIntensity,
            Is.EqualTo(1.02f).Within(0.0001f));
        Assert.That(
            RenderSettings.reflectionIntensity,
            Is.EqualTo(0.08f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(1.08f).Within(0.0001f));
        Assert.That(RenderSettings.fog, Is.False);

        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"), Is.Zero,
            "Companion capture defers the room theme together with the world lights.");

        fixture.ExitCompanionLighting();

        Assert.That(fixture.IsCompanionLightingActive, Is.False);
        Assert.That(fixture.IsNight, Is.True);
        AssertColor(
            RenderSettings.ambientSkyColor,
            new Color(0.25f, 0.28f, 0.36f, 1f));
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(0.68f).Within(0.0001f));
        Assert.That(RenderSettings.fog, Is.True);
        Assert.That(Shader.GetGlobalFloat("_MaasoWorldNightBlend"), Is.EqualTo(1f));
    }

    [Test]
    public void DesktopCompanionLightingLastDeferredDayRequestWins()
    {
        using var fixture = LightingFixture.Create();

        fixture.EnterCompanionLighting();
        fixture.SetTimeOfDay("night");
        fixture.SetTimeOfDay("day");
        fixture.UpdateLighting();
        fixture.UpdateLighting();

        Assert.That(fixture.IsCompanionLightingActive, Is.True);
        Assert.That(fixture.IsNight, Is.False);
        AssertColor(
            RenderSettings.ambientSkyColor,
            new Color(0.43f, 0.43f, 0.425f, 1f));
        Assert.That(
            RenderSettings.ambientIntensity,
            Is.EqualTo(1.02f).Within(0.0001f));
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(1.08f).Within(0.0001f));

        fixture.ExitCompanionLighting();

        Assert.That(fixture.IsCompanionLightingActive, Is.False);
        Assert.That(fixture.IsNight, Is.False);
        AssertColor(RenderSettings.ambientSkyColor, fixture.DayAmbientSky);
        Assert.That(
            fixture.DirectionalLight.intensity,
            Is.EqualTo(fixture.DayLightIntensity).Within(0.0001f));
        Assert.That(RenderSettings.fog, Is.False);
    }

    private static void AssertColor(Color actual, Color expected)
    {
        Assert.That(actual.r, Is.EqualTo(expected.r).Within(0.0001f));
        Assert.That(actual.g, Is.EqualTo(expected.g).Within(0.0001f));
        Assert.That(actual.b, Is.EqualTo(expected.b).Within(0.0001f));
        Assert.That(actual.a, Is.EqualTo(expected.a).Within(0.0001f));
    }

    private static void SetField(Component component, string fieldName, object value)
    {
        FieldInfo field = component.GetType().GetField(
            fieldName,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, fieldName + " should be serialized for scene wiring.");
        field.SetValue(component, value);
    }

    private sealed class LightingFixture : IDisposable
    {
        private readonly RenderSettingsSnapshot snapshot;
        private readonly GameObject lightObject;

        private LightingFixture(
            GameObject cameraObject,
            Camera camera,
            GameObject lightObject,
            Light directionalLight,
            Component controller,
            RenderSettingsSnapshot snapshot)
        {
            CameraObject = cameraObject;
            Camera = camera;
            this.lightObject = lightObject;
            DirectionalLight = directionalLight;
            Controller = controller;
            this.snapshot = snapshot;
            DayBackground = camera.backgroundColor;
            DayLightIntensity = directionalLight.intensity;
            DayAmbientSky = RenderSettings.ambientSkyColor;
        }

        public GameObject CameraObject { get; }
        public Camera Camera { get; }
        public Light DirectionalLight { get; }
        public Component Controller { get; }
        public Color DayBackground { get; }
        public float DayLightIntensity { get; }
        public Color DayAmbientSky { get; }

        public bool IsNight => (bool)Controller.GetType().GetProperty("IsNight")!.GetValue(Controller);
        public bool IsCompanionLightingActive =>
            (bool)Controller.GetType()
                .GetProperty("IsCompanionLightingActive")!
                .GetValue(Controller);

        public static LightingFixture Create()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            RenderSettingsSnapshot snapshot = RenderSettingsSnapshot.Capture();
            var cameraObject = new GameObject("Main Camera");
            cameraObject.tag = "MainCamera";
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(1f, 0.9843137f, 0.9490196f, 1f);
            var lightObject = new GameObject("Directional Light");
            Light directionalLight = lightObject.AddComponent<Light>();
            directionalLight.type = LightType.Directional;
            directionalLight.color = new Color(1f, 0.95686275f, 0.8392157f, 1f);
            directionalLight.intensity = 1f;
            RenderSettings.ambientSkyColor = new Color(0.7f, 0.7f, 0.7f, 1f);
            RenderSettings.ambientEquatorColor = new Color(0.6f, 0.6f, 0.6f, 1f);
            RenderSettings.ambientGroundColor = new Color(0.45f, 0.45f, 0.45f, 1f);
            RenderSettings.fog = false;
            RenderSettings.skybox = null;

            Type controllerType = Type.GetType(ControllerTypeName);
            Assert.That(controllerType, Is.Not.Null, "Unity world lighting controller should exist.");
            Component controller = cameraObject.AddComponent(controllerType);
            SetField(controller, "backgroundCamera", camera);
            SetField(controller, "directionalLight", directionalLight);
            SetField(controller, "transitionSeconds", 0f);
            MethodInfo awake = controllerType.GetMethod(
                "Awake",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(awake, Is.Not.Null);
            awake.Invoke(controller, Array.Empty<object>());

            return new LightingFixture(
                cameraObject,
                camera,
                lightObject,
                directionalLight,
                controller,
                snapshot);
        }

        public void SetTimeOfDay(string timeOfDay)
        {
            MethodInfo method = Controller.GetType().GetMethod("SetTimeOfDay");
            Assert.That(method, Is.Not.Null, "Lighting controller should accept time-of-day commands.");
            method.Invoke(Controller, new object[] { timeOfDay });
        }

        public void EnterCompanionLighting()
        {
            InvokeControllerMethod("EnterCompanionLighting");
        }

        public void ExitCompanionLighting()
        {
            InvokeControllerMethod("ExitCompanionLighting");
        }

        public void UpdateLighting()
        {
            MethodInfo method = Controller.GetType().GetMethod(
                "Update",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(method, Is.Not.Null, "Update should be available.");
            method.Invoke(Controller, Array.Empty<object>());
        }

        private void InvokeControllerMethod(string name)
        {
            MethodInfo method = Controller.GetType().GetMethod(name);
            Assert.That(method, Is.Not.Null, name + " should be available.");
            method.Invoke(Controller, Array.Empty<object>());
        }

        public void Dispose()
        {
            snapshot.Restore();
            UnityEngine.Object.DestroyImmediate(CameraObject);
            UnityEngine.Object.DestroyImmediate(lightObject);
        }
    }

    private readonly struct RenderSettingsSnapshot
    {
        private readonly Color ambientSky;
        private readonly Color ambientEquator;
        private readonly Color ambientGround;
        private readonly AmbientMode ambientMode;
        private readonly float ambientIntensity;
        private readonly float reflectionIntensity;
        private readonly bool fog;
        private readonly FogMode fogMode;
        private readonly Color fogColor;
        private readonly float fogDensity;
        private readonly Material skybox;

        private RenderSettingsSnapshot(
            Color ambientSky,
            Color ambientEquator,
            Color ambientGround,
            AmbientMode ambientMode,
            float ambientIntensity,
            float reflectionIntensity,
            bool fog,
            FogMode fogMode,
            Color fogColor,
            float fogDensity,
            Material skybox)
        {
            this.ambientSky = ambientSky;
            this.ambientEquator = ambientEquator;
            this.ambientGround = ambientGround;
            this.ambientMode = ambientMode;
            this.ambientIntensity = ambientIntensity;
            this.reflectionIntensity = reflectionIntensity;
            this.fog = fog;
            this.fogMode = fogMode;
            this.fogColor = fogColor;
            this.fogDensity = fogDensity;
            this.skybox = skybox;
        }

        public static RenderSettingsSnapshot Capture()
        {
            return new RenderSettingsSnapshot(
                RenderSettings.ambientSkyColor,
                RenderSettings.ambientEquatorColor,
                RenderSettings.ambientGroundColor,
                RenderSettings.ambientMode,
                RenderSettings.ambientIntensity,
                RenderSettings.reflectionIntensity,
                RenderSettings.fog,
                RenderSettings.fogMode,
                RenderSettings.fogColor,
                RenderSettings.fogDensity,
                RenderSettings.skybox);
        }

        public void Restore()
        {
            RenderSettings.ambientSkyColor = ambientSky;
            RenderSettings.ambientEquatorColor = ambientEquator;
            RenderSettings.ambientGroundColor = ambientGround;
            RenderSettings.ambientMode = ambientMode;
            RenderSettings.ambientIntensity = ambientIntensity;
            RenderSettings.reflectionIntensity = reflectionIntensity;
            RenderSettings.fog = fog;
            RenderSettings.fogMode = fogMode;
            RenderSettings.fogColor = fogColor;
            RenderSettings.fogDensity = fogDensity;
            RenderSettings.skybox = skybox;
        }
    }
}
