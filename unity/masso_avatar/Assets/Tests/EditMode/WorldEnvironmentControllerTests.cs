using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class WorldEnvironmentControllerTests
{
    private const string ControllerTypeName =
        "Maaso.World.WorldEnvironmentController, Assembly-CSharp";
    private const string ProfileTypeName =
        "Maaso.World.WorldEnvironmentProfile, Assembly-CSharp";

    [Test]
    public void ConfigurationPreservesLightingAndAmbienceAcrossHomeAndWorld()
    {
        var root = new GameObject("EnvironmentFixture");
        var sunObject = new GameObject("ExistingSun");
        Light previousSun = RenderSettings.sun;
        Color previousAmbient = RenderSettings.ambientSkyColor;
        try
        {
            Light sun = sunObject.AddComponent<Light>();
            sun.type = LightType.Directional;
            RenderSettings.sun = sun;
            RenderSettings.ambientSkyColor = new Color(0.23f, 0.45f, 0.67f, 1f);

            Component controller = CreateController(root, out AudioSource ambience, out _, out _);
            ScriptableObject profile = CreateProfile();
            controller.GetType().GetMethod("Configure")?.Invoke(
                controller,
                new object[] { profile });

            Assert.That(RenderSettings.sun, Is.SameAs(sun));
            Assert.That(
                RenderSettings.ambientSkyColor,
                Is.EqualTo(new Color(0.23f, 0.45f, 0.67f, 1f)));
            Assert.That(ambience.volume, Is.EqualTo(1f).Within(0.001f));

            controller.GetType().GetMethod("SetWorldSessionActive")?.Invoke(
                controller,
                new object[] { false });
            Assert.That(ambience.mute, Is.False);
            controller.GetType().GetMethod("SetWorldSessionActive")?.Invoke(
                controller,
                new object[] { true });
            Assert.That(ambience.mute, Is.False);
        }
        finally
        {
            RenderSettings.sun = previousSun;
            RenderSettings.ambientSkyColor = previousAmbient;
            UnityEngine.Object.DestroyImmediate(root);
            UnityEngine.Object.DestroyImmediate(sunObject);
        }
    }

    [Test]
    public void SpeechDucksOverOneHundredFiftyMillisecondsAndPauseRestoresEffects()
    {
        var root = new GameObject("EnvironmentSpeechFixture");
        try
        {
            Component controller = CreateController(
                root,
                out AudioSource ambience,
                out WindZone wind,
                out ParticleSystem particles);
            controller.GetType().GetMethod("Configure")?.Invoke(
                controller,
                new object[] { CreateProfile() });

            controller.GetType().GetMethod("SetSpeechActive")?.Invoke(
                controller,
                new object[] { true });
            controller.GetType().GetMethod("AdvanceForTests")?.Invoke(
                controller,
                new object[] { 0.15f });
            Assert.That(ambience.volume, Is.EqualTo(0.22f).Within(0.001f));

            controller.GetType().GetMethod("SetSpeechActive")?.Invoke(
                controller,
                new object[] { false });
            controller.GetType().GetMethod("AdvanceForTests")?.Invoke(
                controller,
                new object[] { 0.15f });
            Assert.That(ambience.volume, Is.EqualTo(1f).Within(0.001f));

            controller.GetType().GetMethod("SetApplicationPaused")?.Invoke(
                controller,
                new object[] { true });
            Assert.That(PublicProperty<bool>(controller, "IsApplicationPaused"), Is.True);
            Assert.That(ambience.mute, Is.True);
            Assert.That(wind.windMain, Is.EqualTo(0f).Within(0.001f));
            Assert.That(particles.emission.enabled, Is.False);

            controller.GetType().GetMethod("SetApplicationPaused")?.Invoke(
                controller,
                new object[] { false });
            Assert.That(PublicProperty<bool>(controller, "IsApplicationPaused"), Is.False);
            Assert.That(ambience.mute, Is.False);
            Assert.That(wind.windMain, Is.EqualTo(0.8f).Within(0.001f));
            Assert.That(particles.emission.enabled, Is.True);
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(root);
        }
    }

    private static Component CreateController(
        GameObject root,
        out AudioSource ambience,
        out WindZone wind,
        out ParticleSystem particles)
    {
        Type controllerType = Type.GetType(ControllerTypeName);
        Assert.That(controllerType, Is.Not.Null);
        ambience = root.AddComponent<AudioSource>();
        wind = root.AddComponent<WindZone>();
        particles = root.AddComponent<ParticleSystem>();
        Component controller = root.AddComponent(controllerType);
        SetField(controller, "ambientAudio", ambience);
        SetField(controller, "windZone", wind);
        SetField(controller, "particles", new[] { particles });
        return controller;
    }

    private static ScriptableObject CreateProfile()
    {
        Type profileType = Type.GetType(ProfileTypeName);
        Assert.That(profileType, Is.Not.Null);
        ScriptableObject profile = ScriptableObject.CreateInstance(profileType);
        SetField(profile, "ambientVolume", 1f);
        SetField(profile, "speechDuckedVolume", 0.22f);
        SetField(profile, "speechDuckSeconds", 0.15f);
        SetField(profile, "windMain", 0.8f);
        SetField(profile, "windTurbulence", 0.25f);
        return profile;
    }

    private static T PublicProperty<T>(object target, string name)
    {
        PropertyInfo property = target.GetType().GetProperty(name);
        Assert.That(property, Is.Not.Null, name);
        return (T)property.GetValue(target);
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
