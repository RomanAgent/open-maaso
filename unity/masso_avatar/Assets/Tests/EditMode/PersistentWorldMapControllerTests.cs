using System;
using System.Collections;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;

public sealed class PersistentWorldMapControllerTests
{
    // The existing grounding contract sinks invisible renderer padding by 8 mm.
    private const float GroundedRendererMinimumY = -0.008f;
    private const string ControllerTypeName =
        "Maaso.World.PersistentWorldMapController, Assembly-CSharp";
    private const string PrefabPath =
        "Assets/MaasoWorld/Resources/PersonalSpaceMap.prefab";
    private const string PersonalSpacePrefabPath =
        "Assets/MaasoWorld/Resources/PersonalSpaceModel.prefab";
    private const string PersonalSpaceMaterialPath =
        "Assets/MaasoWorld/Resources/PersonalSpaceWhiteModel.mat";

    [Test]
    public void PersonalSpaceRoomShipsAsASynchronousResource()
    {
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
            PersonalSpacePrefabPath);

        Assert.That(prefab, Is.Not.Null, PersonalSpacePrefabPath);
        Assert.That(prefab.name, Is.EqualTo("PersonalSpaceModel"));
        Assert.That(
            prefab.GetComponentsInChildren<Renderer>(true),
            Is.Not.Empty,
            "The built-in room resource must contain the authored model.");
        Assert.That(
            AssetDatabase.LoadAssetAtPath<Material>(PersonalSpaceMaterialPath),
            Is.Not.Null,
            "The fallback material must remain available in Resources.");
    }

    [Test]
    public void RuntimeMapDefinesStableGroundAndSemanticAnchors()
    {
        Type type = ControllerType();
        MethodInfo ensure = type.GetMethod(
            "EnsureRuntimeMap",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(ensure, Is.Not.Null);
        Component map = (Component)ensure.Invoke(null, null);

        try
        {
            Assert.That(map, Is.Not.Null);
            Assert.That(ensure.Invoke(null, null), Is.SameAs(map));
            Assert.That(
                type.GetField("GroundY", BindingFlags.Public | BindingFlags.Static)
                    ?.GetRawConstantValue(),
                Is.EqualTo(0f));
            Assert.That(Property<Transform>(map, "HomeAgentAnchor"), Is.Not.Null);
            Assert.That(Property<Transform>(map, "WorldPlayCenter"), Is.Not.Null);
            Assert.That(Property<Transform>(map, "WorldDecorationRoot"), Is.Not.Null);
            Assert.That(Property<Collider>(map, "GroundCollider"), Is.Not.Null);

            int spawnCount = 0;
            foreach (object value in Property<IEnumerable>(map, "WorldSpawnAnchors"))
            {
                Assert.That(value, Is.InstanceOf<Transform>());
                spawnCount++;
            }
            Assert.That(spawnCount, Is.GreaterThanOrEqualTo(8));
        }
        finally
        {
            if (map != null)
            {
                UnityEngine.Object.DestroyImmediate(map.gameObject);
            }
        }
    }

    [Test]
    public void RuntimeCoastalRoomPreservesBakedMaterialsAndCoversEightMetres()
    {
        MethodInfo ensure = ControllerType().GetMethod(
            "EnsureRuntimeMap",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(ensure, Is.Not.Null);
        Component map = (Component)ensure.Invoke(null, null);

        try
        {
            Transform ground = map.transform.Find("WorldGround");
            Assert.That(ground, Is.Not.Null);
            Renderer renderer = ground.GetComponent<Renderer>();
            Collider collider = ground.GetComponent<Collider>();
            Assert.That(renderer, Is.Not.Null);
            Assert.That(collider, Is.Not.Null);
            Assert.That(renderer.bounds.size.x, Is.EqualTo(8f).Within(0.01f));
            Assert.That(renderer.bounds.size.z, Is.EqualTo(8f).Within(0.01f));
            Assert.That(collider.bounds.max.y, Is.EqualTo(0f).Within(0.001f));
            Transform whitebox = map.transform.Find(
                "PersistentEnvironmentRoot/BaseVisuals/WhiteboxVisuals");
            Assert.That(whitebox, Is.Not.Null);
            Assert.That(
                whitebox.Find("PersonalSpaceModel"),
                Is.Not.Null,
                "Cold start should synchronously attach the authored PersonalSpace room.");
            Renderer[] whiteboxRenderers = whitebox
                .Find("PersonalSpaceModel")
                .GetComponentsInChildren<Renderer>(true);
            Assert.That(whiteboxRenderers, Is.Not.Empty);
            Material[] materials = whiteboxRenderers
                .SelectMany(value => value.sharedMaterials)
                .Distinct()
                .ToArray();
            Assert.That(materials, Has.None.Null);
            Assert.That(materials.Length, Is.GreaterThanOrEqualTo(5),
                "The runtime map must preserve the authored wood, fabric and greenery.");
            Renderer floor = whiteboxRenderers.Single(value => value.name == "V2_Floor_Baked");
            GameObject sourceModel = AssetDatabase.LoadAssetAtPath<GameObject>(PersonalSpacePrefabPath);
            Renderer sourceFloor = sourceModel.GetComponentsInChildren<Renderer>(true)
                .Single(value => value.name == "V2_Floor_Baked");
            Assert.That(floor.sharedMaterials, Is.EqualTo(sourceFloor.sharedMaterials),
                "Runtime-map generation must preserve every authored floor material slot.");
            Assert.That(floor.sharedMaterial.shader.name, Is.EqualTo("Maaso/CoastalBakedRadiance"));
            Assert.That(floor.sharedMaterial.color, Is.EqualTo(Color.black));
            Assert.That(floor.sharedMaterial.GetColor("_EmissionColor"), Is.EqualTo(Color.white));
            Assert.That(floor.sharedMaterial.GetTexture("_EmissionMap"), Is.SameAs(floor.sharedMaterial.mainTexture));
            Assert.That(floor.sharedMaterial.GetTexture("_EmissionMap"), Is.Not.Null,
                "The runtime floor keeps its baked light and wood texture.");
            string[] names = map
                .GetComponentsInChildren<Transform>(true)
                .Select(value => value.name)
                .ToArray();
            Assert.That(names.Any(value => value.StartsWith("Tree-")), Is.False);
            Assert.That(names.Any(value => value.StartsWith("Road")), Is.False);
            Assert.That(names.Any(value => value.StartsWith("Lamp-")), Is.False);
            Assert.That(names.Any(value => value.StartsWith("PS_Bed_") ||
                value.StartsWith("V2_Bed")), Is.False,
                "The coastal room contains only a living area and workspace.");
            Assert.That(
                map.GetComponentsInChildren<Collider>(true),
                Has.Length.EqualTo(1),
                "The walking-only room must expose one authoritative ground.");

            foreach (Transform spawn in Property<IEnumerable>(
                         map,
                         "WorldSpawnAnchors").Cast<Transform>())
            {
                Assert.That(new Vector2(spawn.position.x, spawn.position.z).magnitude,
                    Is.EqualTo(1.2f).Within(0.001f));
                Assert.That(new Vector2(spawn.position.x, spawn.position.z).magnitude + 0.3f,
                    Is.LessThan(1.55f), "A person must fit inside the central furniture clearance.");
            }
        }
        finally
        {
            if (map != null)
            {
                UnityEngine.Object.DestroyImmediate(map.gameObject);
            }
        }
    }

    [Test]
    public void AuthoredFloorHidesThePrimitiveWithoutDisablingWalking()
    {
        var root = new GameObject("CoastalGroundFallbackFixture");
        try
        {
            Component map = (Component)ControllerType()
                .GetMethod("BuildDefaultMap", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, new object[] { root });
            Collider ground = Property<Collider>(map, "GroundCollider");
            Renderer primitive = ground.GetComponent<Renderer>();
            MethodInfo setVisible = ControllerType().GetMethod("SetPrimitiveFallbackVisible");
            setVisible.Invoke(map, new object[] { true });
            Assert.That(primitive.enabled, Is.True, "Missing art needs a visible fallback floor.");

            GameObject model = GameObject.CreatePrimitive(PrimitiveType.Cube);
            model.name = "PersonalSpaceModel";
            model.transform.SetParent(root.transform.Find(
                "PersistentEnvironmentRoot/BaseVisuals/WhiteboxVisuals"), false);
            UnityEngine.Object.DestroyImmediate(model.GetComponent<Collider>());
            foreach (bool worldActive in new[] { false, true, false })
            {
                ControllerType().GetMethod("SetWorldActive").Invoke(map, new object[] { worldActive });
                Assert.That(primitive.enabled, Is.False,
                    "Home/world transitions must not cover the authored floor with the neutral primitive.");
                Assert.That(ground.enabled, Is.True);
                Assert.That(ground.gameObject.activeInHierarchy, Is.True);
            }

            model.SetActive(false);
            setVisible.Invoke(map, new object[] { true });
            Assert.That(primitive.enabled, Is.True);
            Assert.That(ground.enabled, Is.True);
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(root);
        }
    }

    [Test]
    public void LegacyMetropiaLoaderTypeIsRemoved()
    {
        Assert.That(
            Type.GetType("Maaso.World.NatureParkSceneLoader, Assembly-CSharp"),
            Is.Null);
    }

    [Test]
    public void WorldDecorationsAreGroupedAndHiddenOutsideWorldSessions()
    {
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(PrefabPath);
        Assert.That(prefab, Is.Not.Null, PrefabPath);
        GameObject instance = UnityEngine.Object.Instantiate(prefab);

        try
        {
            Type type = ControllerType();
            Component map = instance.GetComponent(type);
            Assert.That(map, Is.Not.Null);
            Transform persistentRoot = Property<Transform>(map, "PersistentEnvironmentRoot");
            Transform decorationRoot = Property<Transform>(map, "WorldDecorationRoot");
            Transform baseVisuals = instance.transform.Find("PersistentEnvironmentRoot/BaseVisuals");
            Transform environment = instance.transform.Find("PersistentEnvironmentRoot/EnvironmentProps");
            Transform ground = instance.transform.Find("WorldGround");

            Assert.That(baseVisuals, Is.Not.Null,
                "Roads and plaza visuals must remain visible in Home and World.");
            Assert.That(environment, Is.Not.Null,
                "Environment props must remain visible in Home and World.");
            Assert.That(ground, Is.Not.Null);

            type.GetMethod("SetWorldActive")?.Invoke(map, new object[] { false });
            Assert.That(persistentRoot.gameObject.activeSelf, Is.True);
            Assert.That(decorationRoot.gameObject.activeSelf, Is.False);
            Assert.That(ground.gameObject.activeSelf, Is.True,
                "Home keeps the physical ground available for avatar grounding.");

            type.GetMethod("SetWorldActive")?.Invoke(map, new object[] { true });
            Assert.That(persistentRoot.gameObject.activeSelf, Is.True);
            Assert.That(decorationRoot.gameObject.activeSelf, Is.True);
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(instance);
        }
    }

    [Test]
    public void ProjectToGroundUsesTheRegisteredWalkingSurfaceHeight()
    {
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(PrefabPath);
        Assert.That(prefab, Is.Not.Null, PrefabPath);
        GameObject instance = UnityEngine.Object.Instantiate(prefab);
        GameObject elevatedGround = GameObject.CreatePrimitive(PrimitiveType.Cube);
        elevatedGround.transform.position = new Vector3(0f, 2.95f, 0f);
        elevatedGround.transform.localScale = new Vector3(8f, 0.1f, 8f);

        try
        {
            Component map = instance.GetComponent(ControllerType());
            SetField(map, "groundCollider", elevatedGround.GetComponent<Collider>());
            Physics.SyncTransforms();

            MethodInfo project = ControllerType().GetMethod(
                "ProjectToGround",
                BindingFlags.Public | BindingFlags.Instance);
            Assert.That(project, Is.Not.Null);
            Vector3 result = (Vector3)project.Invoke(
                map,
                new object[] { new Vector3(1f, -20f, 1f) });

            Assert.That(result.x, Is.EqualTo(1f).Within(0.001f));
            Assert.That(result.y, Is.EqualTo(3f).Within(0.001f));
            Assert.That(result.z, Is.EqualTo(1f).Within(0.001f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(elevatedGround);
            UnityEngine.Object.DestroyImmediate(instance);
        }
    }

    [Test]
    public void HomeAlignmentRebasesBodyPoseAbovePersistentGround()
    {
        var mapRoot = new GameObject("HomeAlignmentMap");
        var receiverHost = new GameObject("AvatarReceiver");
        var avatarRoot = new GameObject("ActiveAvatar");
        GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
        body.transform.SetParent(avatarRoot.transform, false);
        body.transform.localPosition = new Vector3(0f, -0.75f, 0f);

        try
        {
            Type receiverType = Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverHost.AddComponent(receiverType);
            SetField(receiver, "avatarRoot", avatarRoot.transform);
            SetField(receiver, "hasBaseRootPose", false);
            MethodInfo ensureAvatar = receiverType.GetMethod(
                "EnsureAvatar",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(ensureAvatar, Is.Not.Null);
            ensureAvatar.Invoke(receiver, Array.Empty<object>());

            Type mapType = ControllerType();
            Component map = mapRoot.AddComponent(mapType);
            var homeAnchor = new GameObject("HomeAgentAnchor").transform;
            homeAnchor.SetParent(mapRoot.transform, false);
            SetField(map, "homeAgentAnchor", homeAnchor);
            SetField(map, "avatarReceiver", receiver);

            MethodInfo align = mapType.GetMethod("AlignHomeAvatar");
            Assert.That(align, Is.Not.Null);
            Assert.That(
                align.Invoke(map, new object[] { avatarRoot.transform }),
                Is.EqualTo(true));
            Assert.That(
                body.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(GroundedRendererMinimumY).Within(0.001f));

            receiverType.GetMethod("OnFlutterCommand")?.Invoke(
                receiver,
                new object[]
                {
                    "{\"method\":\"setBodyPose\",\"json\":\"{\\\"x\\\":0,\\\"y\\\":0,\\\"z\\\":0,\\\"durationMs\\\":0}\"}",
                });

            Assert.That(
                body.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(GroundedRendererMinimumY).Within(0.001f),
                "Home body-pose commands must use the grounded root as their baseline.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(mapRoot);
            UnityEngine.Object.DestroyImmediate(receiverHost);
            UnityEngine.Object.DestroyImmediate(avatarRoot);
        }
    }

    [Test]
    public void HomeAlignmentGroundsAndFramesAvatar()
    {
        var mapRoot = new GameObject("HomeCameraAlignmentMap");
        var avatarRoot = new GameObject("HomeCameraAvatar");
        var cameraObject = new GameObject("HomeCamera");
        GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
        body.transform.SetParent(avatarRoot.transform, false);
        body.transform.localPosition = new Vector3(0f, 0.5f, 0f);
        avatarRoot.transform.position = new Vector3(2f, -2f, 1f);

        try
        {
            Type mapType = ControllerType();
            Component map = mapRoot.AddComponent(mapType);
            var homeAnchor = new GameObject("HomeAgentAnchor").transform;
            homeAnchor.SetParent(mapRoot.transform, false);
            SetField(map, "homeAgentAnchor", homeAnchor);

            Camera camera = cameraObject.AddComponent<Camera>();
            Type framingType = Type.GetType(
                "Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp");
            Assert.That(framingType, Is.Not.Null);
            Component framing = cameraObject.AddComponent(framingType);
            framingType.GetProperty("TargetRoot")?.SetValue(
                framing,
                avatarRoot.transform);

            var cameraOffset = new Vector3(0f, 1.2f, 4f);
            camera.transform.position = avatarRoot.transform.position + cameraOffset;

            MethodInfo align = mapType.GetMethod("AlignHomeAvatar");
            Assert.That(align, Is.Not.Null);
            Assert.That(
                align.Invoke(map, new object[] { avatarRoot.transform }),
                Is.EqualTo(true));

            Assert.That(
                body.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(GroundedRendererMinimumY).Within(0.001f),
                "The avatar's visible feet must contact the floor with the existing renderer-padding inset.");
            Assert.That(
                framingType.GetProperty("TargetRoot")?.GetValue(framing),
                Is.SameAs(avatarRoot.transform));
            Vector3 directionToAvatar =
                (body.GetComponent<Renderer>().bounds.center -
                    camera.transform.position).normalized;
            Assert.That(
                Vector3.Dot(camera.transform.forward, directionToAvatar),
                Is.GreaterThan(0.99f),
                "Home framing must look at the grounded avatar's full-body bounds.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(mapRoot);
            UnityEngine.Object.DestroyImmediate(avatarRoot);
            UnityEngine.Object.DestroyImmediate(cameraObject);
        }
    }

    [Test]
    public void SetWorldInactiveImmediatelyAlignsAndFramesActiveAvatar()
    {
        var mapRoot = new GameObject("ImmediateHomeAlignmentMap");
        var receiverHost = new GameObject("ImmediateHomeReceiver");
        var avatarRoot = new GameObject("ImmediateHomeAvatar");
        var cameraObject = new GameObject("ImmediateHomeCamera");
        GameObject body = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        body.transform.SetParent(avatarRoot.transform, false);
        body.transform.localPosition = Vector3.up;
        avatarRoot.transform.position = new Vector3(0f, -2f, 0f);

        try
        {
            Type receiverType = Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverHost.AddComponent(receiverType);
            SetField(receiver, "avatarRoot", avatarRoot.transform);
            SetField(receiver, "bundledAvatarRoot", avatarRoot.transform);

            Type framingType = Type.GetType(
                "Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp");
            Assert.That(framingType, Is.Not.Null);
            cameraObject.tag = "MainCamera";
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.fieldOfView = 37.5f;
            Component framing = cameraObject.AddComponent(framingType);
            framingType.GetProperty("TargetRoot")?.SetValue(
                framing,
                avatarRoot.transform);

            Type mapType = ControllerType();
            Component map = mapRoot.AddComponent(mapType);
            var homeAnchor = new GameObject("ImmediateHomeAnchor").transform;
            homeAnchor.SetParent(mapRoot.transform, false);
            SetField(map, "homeAgentAnchor", homeAnchor);
            SetField(map, "avatarReceiver", receiver);

            mapType.GetMethod("SetWorldActive")?.Invoke(
                map,
                new object[] { false });

            Bounds bounds = body.GetComponent<Renderer>().bounds;
            Assert.That(bounds.min.y, Is.EqualTo(GroundedRendererMinimumY).Within(0.001f));
            Assert.That(
                framingType.GetProperty("TargetRoot")?.GetValue(framing),
                Is.SameAs(avatarRoot.transform));
            Vector3 directionToAvatar =
                (bounds.center - camera.transform.position).normalized;
            Assert.That(
                Vector3.Dot(camera.transform.forward, directionToAvatar),
                Is.GreaterThan(0.99f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(avatarRoot);
            UnityEngine.Object.DestroyImmediate(receiverHost);
            UnityEngine.Object.DestroyImmediate(mapRoot);
        }
    }

    [Test]
    public void ColdStartRealignsWhenAvatarBoundsExpandAfterFirstFrame()
    {
        var mapRoot = new GameObject("ColdStartHomeMap");
        var receiverHost = new GameObject("ColdStartAvatarReceiver");
        var avatarRoot = new GameObject("ColdStartAvatar");
        GameObject initialBody = GameObject.CreatePrimitive(PrimitiveType.Cube);
        initialBody.transform.SetParent(avatarRoot.transform, false);
        initialBody.transform.localPosition = Vector3.up * 0.5f;

        try
        {
            Type receiverType = Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverHost.AddComponent(receiverType);
            SetField(receiver, "avatarRoot", avatarRoot.transform);
            SetField(receiver, "bundledAvatarRoot", avatarRoot.transform);

            Type mapType = ControllerType();
            Component map = mapRoot.AddComponent(mapType);
            var homeAnchor = new GameObject("ColdStartHomeAnchor").transform;
            homeAnchor.SetParent(mapRoot.transform, false);
            SetField(map, "homeAgentAnchor", homeAnchor);
            SetField(map, "avatarReceiver", receiver);

            mapType.GetMethod("SetWorldActive")?.Invoke(
                map,
                new object[] { false });

            GameObject lateLowerBody = GameObject.CreatePrimitive(PrimitiveType.Cube);
            lateLowerBody.name = "LateEvaluatedLowerBody";
            lateLowerBody.transform.SetParent(avatarRoot.transform, false);
            lateLowerBody.transform.localPosition = Vector3.down * 0.5f;

            MethodInfo tryAlign = mapType.GetMethod(
                "TryAlignActiveHomeAvatar",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(tryAlign, Is.Not.Null);
            tryAlign.Invoke(map, Array.Empty<object>());

            Assert.That(
                lateLowerBody.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(GroundedRendererMinimumY).Within(0.001f),
                "Cold-start alignment must be repaired after the full skinned bounds become available.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(avatarRoot);
            UnityEngine.Object.DestroyImmediate(receiverHost);
            UnityEngine.Object.DestroyImmediate(mapRoot);
        }
    }

    [Test]
    public void ColdStartKeepsRealigningWhileAvatarBoundsAreStillExpanding()
    {
        var mapRoot = new GameObject("SettlingColdStartHomeMap");
        var receiverHost = new GameObject("SettlingColdStartAvatarReceiver");
        var avatarRoot = new GameObject("SettlingColdStartAvatar");
        GameObject initialBody = GameObject.CreatePrimitive(PrimitiveType.Cube);
        initialBody.transform.SetParent(avatarRoot.transform, false);
        initialBody.transform.localPosition = Vector3.up * 0.5f;

        try
        {
            Type receiverType = Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverHost.AddComponent(receiverType);
            SetField(receiver, "avatarRoot", avatarRoot.transform);
            SetField(receiver, "bundledAvatarRoot", avatarRoot.transform);

            Type mapType = ControllerType();
            Component map = mapRoot.AddComponent(mapType);
            var homeAnchor = new GameObject("SettlingColdStartHomeAnchor").transform;
            homeAnchor.SetParent(mapRoot.transform, false);
            SetField(map, "homeAgentAnchor", homeAnchor);
            SetField(map, "avatarReceiver", receiver);

            mapType.GetMethod("SetWorldActive")?.Invoke(
                map,
                new object[] { false });

            GameObject firstLateBody = GameObject.CreatePrimitive(PrimitiveType.Cube);
            firstLateBody.name = "FirstLateEvaluatedLowerBody";
            firstLateBody.transform.SetParent(avatarRoot.transform, false);
            firstLateBody.transform.localPosition = Vector3.down * 0.5f;

            MethodInfo tryAlign = mapType.GetMethod(
                "TryAlignActiveHomeAvatar",
                BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(tryAlign, Is.Not.Null);
            tryAlign.Invoke(map, Array.Empty<object>());

            GameObject finalLateBody = GameObject.CreatePrimitive(PrimitiveType.Cube);
            finalLateBody.name = "FinalLateEvaluatedLowerBody";
            finalLateBody.transform.SetParent(avatarRoot.transform, false);
            finalLateBody.transform.localPosition = Vector3.down * 1.5f;

            tryAlign.Invoke(map, Array.Empty<object>());

            Assert.That(
                finalLateBody.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(GroundedRendererMinimumY).Within(0.001f),
                "Home alignment must not lock after one retry while the Animator is still expanding the skinned bounds.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(avatarRoot);
            UnityEngine.Object.DestroyImmediate(receiverHost);
            UnityEngine.Object.DestroyImmediate(mapRoot);
        }
    }



    private static Type ControllerType()
    {
        Type type = Type.GetType(ControllerTypeName);
        Assert.That(type, Is.Not.Null, "PersistentWorldMapController should exist.");
        return type;
    }

    private static T Property<T>(object target, string name)
    {
        PropertyInfo property = target.GetType().GetProperty(
            name,
            BindingFlags.Public | BindingFlags.Instance);
        Assert.That(property, Is.Not.Null, name);
        return (T)property.GetValue(target);
    }

    private static void SetField(Component component, string name, object value)
    {
        FieldInfo field = component.GetType().GetField(
            name,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, name);
        field.SetValue(component, value);
    }

}
