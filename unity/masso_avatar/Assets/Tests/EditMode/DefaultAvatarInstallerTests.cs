using System;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.SceneManagement;

public sealed class DefaultAvatarInstallerTests
{
    private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
    private const string ModelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";

    [TearDown]
    public void RestoreSceneWithoutSaving()
    {
        EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
    }

    [Test]
    public void ReplacementPreservesAuthoredWorldCameraLightingAndController()
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Component receiver = FindReceiver(scene);
        Transform previous = BoundRoot(receiver);
        Animator previousAnimator = previous.GetComponentInChildren<Animator>(true);
        var controller = previousAnimator.runtimeAnimatorController;
        var outside = scene.GetRootGameObjects()
            .SelectMany(root => root.GetComponentsInChildren<Transform>(true))
            .Where(item => !item.IsChildOf(previous)).ToArray();
        var beforeTransforms = outside.Select(item =>
            (item, item.parent, item.localPosition, item.localRotation, item.localScale)).ToArray();
        Camera[] cameras = outside.SelectMany(item => item.GetComponents<Camera>()).ToArray();
        string[] cameraJson = cameras.Select(camera => EditorJsonUtility.ToJson(camera)).ToArray();
        Light[] lights = outside.SelectMany(item => item.GetComponents<Light>()).ToArray();
        string[] lightJson = lights.Select(light => EditorJsonUtility.ToJson(light)).ToArray();
        Renderer[] renderers = outside.SelectMany(item => item.GetComponents<Renderer>()).ToArray();
        var materials = renderers.Select(renderer => renderer.sharedMaterials).ToArray();
        var ambient = RenderSettings.ambientLight;
        var skybox = RenderSettings.skybox;
        var sun = RenderSettings.sun;
        var buildSettings = EditorBuildSettings.scenes.Select(item => (item.path, item.enabled)).ToArray();
        Vector3 position = previous.localPosition, scale = previous.localScale;
        Quaternion rotation = previous.localRotation;

        GameObject installed = Install(scene, ModelPath);

        Assert.That(previous == null, Is.True);
        Assert.That(BoundRoot(receiver), Is.SameAs(installed.transform));
        Assert.That(installed.transform.localPosition, Is.EqualTo(position));
        Assert.That(installed.transform.localRotation, Is.EqualTo(rotation));
        Assert.That(installed.transform.localScale, Is.EqualTo(scale));
        Assert.That(installed.GetComponentInChildren<Animator>(true).runtimeAnimatorController,
            Is.SameAs(controller));
        Assert.That(new SerializedObject(receiver).FindProperty("bundledVrmInstance").objectReferenceValue,
            Is.SameAs(installed.GetComponentInChildren<Vrm10Instance>(true)));
        Assert.That(scene.GetRootGameObjects().SelectMany(root =>
            root.GetComponentsInChildren<Vrm10Instance>(true)).Count(), Is.EqualTo(1));
        Assert.That(AssetDatabase.GetAssetPath(PrefabUtility.GetCorrespondingObjectFromSource(installed)),
            Is.EqualTo(ModelPath));

        foreach (var (item, parent, localPosition, localRotation, localScale) in beforeTransforms)
        {
            Assert.That(item != null, Is.True);
            Assert.That(item.parent, Is.SameAs(parent));
            Assert.That(item.localPosition, Is.EqualTo(localPosition));
            Assert.That(item.localRotation, Is.EqualTo(localRotation));
            Assert.That(item.localScale, Is.EqualTo(localScale));
        }
        for (int index = 0; index < cameras.Length; index++)
            Assert.That(EditorJsonUtility.ToJson(cameras[index]), Is.EqualTo(cameraJson[index]));
        for (int index = 0; index < lights.Length; index++)
            Assert.That(EditorJsonUtility.ToJson(lights[index]), Is.EqualTo(lightJson[index]));
        for (int index = 0; index < renderers.Length; index++)
            Assert.That(renderers[index].sharedMaterials, Is.EqualTo(materials[index]));
        Assert.That(RenderSettings.ambientLight, Is.EqualTo(ambient));
        Assert.That(RenderSettings.skybox, Is.SameAs(skybox));
        Assert.That(RenderSettings.sun, Is.SameAs(sun));
        Assert.That(EditorBuildSettings.scenes.Select(item => (item.path, item.enabled)).ToArray(),
            Is.EqualTo(buildSettings));

        Component framing = outside.SelectMany(item => item.GetComponents<Component>())
            .Single(item => item.GetType().Name == "FrontFullBodyCamera");
        Assert.That(new SerializedObject(framing).FindProperty("targetRoot").objectReferenceValue,
            Is.SameAs(installed.transform));
    }

    [Test]
    public void UnknownExternalAvatarReferenceRejectsReplacementWithoutClearingIt()
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Component receiver = FindReceiver(scene);
        Transform previous = BoundRoot(receiver);
        var legacy = new GameObject("LegacyAvatarOnlyAnchor");
        legacy.transform.SetParent(previous, false);
        var observer = new GameObject("ExternalAnchorConsumer");
        var constraint = observer.AddComponent<LookAtConstraint>();
        constraint.AddSource(new UnityEngine.Animations.ConstraintSource
            { sourceTransform = legacy.transform, weight = 1f });

        var error = Assert.Throws<InvalidOperationException>(() => Install(scene, ModelPath));

        Assert.That(error.Message, Does.Contain("Unmapped avatar reference"));
        Assert.That(BoundRoot(receiver), Is.SameAs(previous));
        Assert.That(previous != null, Is.True);
        Assert.That(constraint.GetSource(0).sourceTransform, Is.SameAs(legacy.transform));
        Assert.That(scene.GetRootGameObjects().SelectMany(root =>
            root.GetComponentsInChildren<Vrm10Instance>(true)).Count(), Is.EqualTo(1));
    }

    [Test]
    public void MissingModelLeavesTheCurrentAvatarBound()
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Component receiver = FindReceiver(scene);
        Transform previous = BoundRoot(receiver);
        Assert.Throws<InvalidOperationException>(() => Install(scene, "Assets/Missing-Joy.vrm"));
        Assert.That(BoundRoot(receiver), Is.SameAs(previous));
    }

    private static Component FindReceiver(Scene scene) => scene.GetRootGameObjects()
        .SelectMany(root => root.GetComponentsInChildren<Component>(true))
        .Single(item => item != null && item.GetType().Name == "UnityAvatarCommandReceiver");

    private static Transform BoundRoot(Component receiver) =>
        new SerializedObject(receiver).FindProperty("avatarRoot").objectReferenceValue as Transform;

    private static GameObject Install(Scene scene, string modelPath)
    {
        Type installer = AppDomain.CurrentDomain.GetAssemblies()
            .Select(assembly => assembly.GetType("Maaso.Avatar.Editor.MaasoDefaultAvatarInstaller"))
            .Single(type => type != null);
        try
        {
            return (GameObject)installer.GetMethod("InstallInScene", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, new object[] { scene, modelPath });
        }
        catch (TargetInvocationException error) when (error.InnerException != null)
        {
            throw error.InnerException;
        }
    }
}
