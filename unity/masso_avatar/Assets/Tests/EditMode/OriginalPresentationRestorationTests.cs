using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class OriginalPresentationRestorationTests
{
    private const string RoomFbx = "Assets/MaasoWorld/PersonalSpace/CoastalV4/PersonalSpaceV4.fbx";
    private const string MapPrefab = "Assets/MaasoWorld/Resources/PersonalSpaceMap.prefab";
    private static Type RuntimeType(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static string Hash(string path)
    {
        using var sha = SHA256.Create();
        using var stream = File.OpenRead(path);
        return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    [Test]
    public void OriginalRoomFbxAndBothPresentationPostersMatchTheirReviewedBytes()
    {
        Assert.That(Hash(RoomFbx), Is.EqualTo("e935d7d37436e74e32f58cd0e3e899a8da7096c290d0a01b9e065c43863ea8d5"));
        string root = Path.GetFullPath(Path.Combine(Application.dataPath, "../../.."));
        Assert.That(Hash(Path.Combine(root, "assets/brand/home_room.png")), Is.EqualTo("747211147fd0c0098e1dc0c0df9ccebf7dc5f6bd69b6d3e50961e56937ad2600"));
        Assert.That(Hash(Path.Combine(root, "assets/brand/login_doorway.png")), Is.EqualTo("1eef57cfcb95723b214888f7928055d60d297038b419e4e22f216f1485f077d7"));
    }

    [Test]
    public void ActualImportedRoomContainsStaticRoomMeshesAndNoCharacterOrMotionAssets()
    {
        var asset = AssetDatabase.LoadAssetAtPath<GameObject>(RoomFbx);
        Assert.That(asset, Is.Not.Null);
        Assert.That(asset.GetComponentsInChildren<SkinnedMeshRenderer>(true), Is.Empty);
        Assert.That(asset.GetComponentsInChildren<Animator>(true).Any(value => value.isHuman || value.avatar != null), Is.False);
        Object[] subassets = AssetDatabase.LoadAllAssetsAtPath(RoomFbx);
        var meshes = subassets.OfType<Mesh>().ToArray();
        Assert.That(meshes, Has.Length.EqualTo(96));
        Assert.That(subassets.OfType<Avatar>(), Is.Empty);
        Assert.That(subassets.OfType<AnimationClip>(), Is.Empty);
        foreach (string name in asset.GetComponentsInChildren<Transform>(true).Select(value => value.name))
        {
            if (name == "V4_HomeAvatar") continue; // Original empty Home placement anchor, not a character.
            Assert.That(System.Text.RegularExpressions.Regex.IsMatch(name,
                @"(^|[_. ])(Matt|Joy|Avatar|Character|Armature|Hips|Spine|UpperArm)([_. ]|$)",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase), Is.False, name);
        }
        Type.GetType("Maaso.Avatar.Editor.OpenMaasoLoginDoorwayVerification, Assembly-CSharp-Editor", true)
            .GetMethod("AuditOriginalRoom").Invoke(null, null);
    }

    [Test]
    public void OriginalRoomPrefabRetainsOneSharedSceneEntryAndReviewedDependency()
    {
        var map = AssetDatabase.LoadAssetAtPath<GameObject>(MapPrefab);
        Assert.That(map, Is.Not.Null);
        Component[] entries = map.GetComponentsInChildren(RuntimeType("LoginDoorwayRig"), true);
        Assert.That(entries, Has.Length.EqualTo(1));
        object binding = entries[0].GetType().GetProperty("SceneEntry").GetValue(entries[0]);
        Assert.That(binding.GetType().GetField("EntryId").GetValue(binding), Is.EqualTo("main_entry"));
        Assert.That(binding.GetType().GetField("SceneRevision").GetValue(binding), Is.EqualTo("a18e70d228ca51155bae0a4ea6a492ac691a76af00c5b08a9bcad119b1e065d0"));
        Assert.That(AssetDatabase.GetDependencies(MapPrefab, true), Does.Contain(RoomFbx));
        Assert.That(map.GetComponentsInChildren<Transform>(true).Any(value => value.name == "OpenMaasoSharedEntrance" || value.name == "InteriorWhiteBackdrop" || value.name == "OfflineWhiteFloor"), Is.False);
        Assert.That(LayerMask.NameToLayer("PersonalSpaceEnvironment"), Is.EqualTo(8));
    }

    [Test]
    public void RebuiltDefaultSceneUsesOriginalRoomAndPortraitCameraRatherThanGenericGeometry()
    {
        var scene = EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
        var camera = scene.GetRootGameObjects().SelectMany(root => root.GetComponentsInChildren<Camera>(true)).Single(value => value.CompareTag("MainCamera"));
        Component portrait = camera.GetComponent(RuntimeType("PortraitDepthOfField"));
        Assert.That(portrait, Is.Not.Null);
        Assert.That(new SerializedObject(portrait).FindProperty("blurRadius").floatValue, Is.EqualTo(3.5f));
        var framing = new SerializedObject(camera.GetComponent(RuntimeType("FrontFullBodyCamera")));
        Assert.That(framing.FindProperty("framingPadding").floatValue, Is.EqualTo(1f));
        Assert.That(framing.FindProperty("topSafeViewport").floatValue, Is.EqualTo(.15f));
        Assert.That(framing.FindProperty("bottomSafeViewport").floatValue, Is.EqualTo(.2f));
        Assert.That(camera.fieldOfView, Is.EqualTo(37.5f));
        var map = scene.GetRootGameObjects().Single(root => root.name == "PersonalSpaceMap");
        Assert.That(PrefabUtility.GetPrefabAssetPathOfNearestInstanceRoot(map), Is.EqualTo(MapPrefab));
        Assert.That(scene.GetRootGameObjects().SelectMany(root => root.GetComponentsInChildren<Transform>(true)).Any(value => value.name == "OpenMaasoSharedEntrance" || value.name == "OfflineWhiteFloor"), Is.False);
    }
}
