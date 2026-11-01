using System;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

public sealed class PersonalSpaceAuthoringSceneTests
{
    private const string ScenePath =
        "Assets/MaasoWorld/Scenes/PersonalSpace.unity";
    private const string ModelPath =
        "Assets/MaasoWorld/PersonalSpace/Models/PersonalSpace.fbx";
    private const string BuilderTypeName =
        "Maaso.World.Editor.PersonalSpaceSceneBuilder, Assembly-CSharp-Editor";

    [Test]
    public void ImportedSourceAndGeneratedAuthoringSceneAreAvailable()
    {
        Assert.That(AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath), Is.Not.Null);
        Assert.That(Type.GetType(BuilderTypeName), Is.Not.Null);
        Assert.That(AssetDatabase.LoadAssetAtPath<SceneAsset>(ScenePath), Is.Not.Null);

        EditorBuildSettingsScene buildScene = Array.Find(
            EditorBuildSettings.scenes,
            candidate => candidate.path == ScenePath);
        Assert.That(
            buildScene,
            Is.Null,
            "The authoring scene must not ship in player Build Settings.");
    }

    [Test]
    public void AuthoringSceneKeepsPersonalSpaceRenderingButOwnsNoGameplayOrCamera()
    {
        WithScene(root =>
        {
            Assert.That(root.name, Is.EqualTo("PersonalSpaceSceneRoot"));
            Assert.That(
                Components(root, "Maaso.World.WorldEnvironmentController"),
                Has.Length.EqualTo(1));
            Assert.That(
                Components(root, "Maaso.World.WorldQualityController"),
                Has.Length.EqualTo(1));
            Assert.That(
                Components(root, "Maaso.World.PersistentWorldMapController"),
                Is.Empty);
            Assert.That(root.GetComponentsInChildren<Camera>(true), Is.Empty);
            Assert.That(root.GetComponentsInChildren<AudioListener>(true), Is.Empty);
            Assert.That(
                root.GetComponentsInChildren<Light>(true),
                Is.Empty,
                "The baked environment must add no lights to the app.");

            Collider[] colliders = root.GetComponentsInChildren<Collider>(true);
            Assert.That(colliders, Has.Length.EqualTo(1));
            Assert.That(colliders[0], Is.TypeOf<BoxCollider>());
            var ground = (BoxCollider)colliders[0];
            Assert.That(ground.bounds.size.x, Is.EqualTo(8f).Within(0.01f));
            Assert.That(ground.bounds.size.z, Is.EqualTo(8f).Within(0.01f));
            Assert.That(ground.bounds.max.y, Is.EqualTo(0f).Within(0.001f));
            Assert.That(
                colliders.Where(value => value != ground),
                Is.Empty,
                "Furniture must not block tap-to-move navigation.");
            Assert.That(root.GetComponentsInChildren<Renderer>(true).Length, Is.GreaterThanOrEqualTo(12));

            Transform environment = root.transform.Find(
                "PersonalSpaceEnvironment");
            Assert.That(environment, Is.Not.Null);
            Assert.That(environment.localPosition, Is.EqualTo(Vector3.zero));
            Assert.That(environment.Find("PersonalSpaceModel"), Is.Not.Null);

            int missingScripts = root
                .GetComponentsInChildren<Transform>(true)
                .Sum(value => GameObjectUtility.GetMonoBehavioursWithMissingScriptCount(
                    value.gameObject));
            Assert.That(missingScripts, Is.Zero);
            Assert.That(
                root.GetComponentsInChildren<Transform>(true).Any(value =>
                    PrefabUtility.GetPrefabAssetType(value.gameObject) ==
                    PrefabAssetType.MissingAsset),
                Is.False);
        });
    }

    private static void WithScene(Action<GameObject> assertion)
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Additive);
        try
        {
            Assert.That(scene.isLoaded, Is.True, ScenePath);
            GameObject root = Array.Find(
                scene.GetRootGameObjects(),
                candidate => candidate.name == "PersonalSpaceSceneRoot");
            Assert.That(root, Is.Not.Null, ScenePath);
            assertion(root);
        }
        finally
        {
            EditorSceneManager.CloseScene(scene, true);
        }
    }

    private static Component[] Components(GameObject root, string fullName)
    {
        Type type = Type.GetType(fullName + ", Assembly-CSharp");
        Assert.That(type, Is.Not.Null, fullName);
        return root.GetComponentsInChildren(type, true).Cast<Component>().ToArray();
    }
}
