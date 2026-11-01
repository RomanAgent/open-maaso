using System;
using System.IO;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

public sealed class FrontFullBodyCameraTests
{
    private const string ComponentTypeName = "Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp";
    private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
    private const string DaySkyMaterialPath =
        "Assets/MaasoWorld/Resources/Maaso_DaySky.mat";
    private const string LegacyHdrPath =
        "Assets/MaasoWorld/Sky/kloofendal_48d_partly_cloudy_puresky_2k.hdr";

    [TestCase(390f / 844f, 180f, 0f)]
    [TestCase(9f / 16f, 180f, 0f)]
    [TestCase(390f / 844f, 225f, 0f)]
    [TestCase(390f / 844f, 180f, 0.3f)]
    public void HomeFullBodyStaysInsideRoomAndFitsEveryBoundsCorner(float aspect, float heading, float bodyDepth)
    {
        using var fixture = new HomeRoomFramingFixture(aspect);
        fixture.Root.transform.position = new Vector3(bodyDepth * 0.5f, 0f, bodyDepth);
        fixture.Reference.rotation = Quaternion.Euler(0f, heading, 0f);
        fixture.Call("SetHomeViewReference", fixture.Reference);
        fixture.Call("FrameNow");

        Camera camera = fixture.Camera;
        Assert.That(fixture.Reference.localPosition.z, Is.EqualTo(3.2f));
        Bounds bounds = fixture.Body.bounds;
        Vector3 front = -fixture.Reference.forward;
        Assert.That(fixture.Type.GetProperty("FramingMode").GetValue(fixture.Framing),
            Is.EqualTo("hero_full_body"), "The default Home mode must use the room fit.");
        Assert.That(Vector3.Dot(camera.transform.position - bounds.center, front),
            Is.InRange(0f, 3.2001f));
        Assert.That(Vector3.Dot(camera.transform.position - fixture.Reference.position, front),
            Is.LessThanOrEqualTo(0.0001f), "Animated or offset bounds cannot move the room's camera safety plane.");
        Assert.That(Mathf.Abs(camera.transform.position.z), Is.LessThan(4f),
            "A real 390/844 phone must not push the camera through the eight-metre room wall.");
        Assert.That(camera.fieldOfView, Is.GreaterThan(HomeRoomFramingFixture.AuthoredFieldOfView));
        Assert.That(Vector3.Dot(camera.transform.forward, fixture.Reference.forward),
            Is.GreaterThan(0.9999f));
        Assert.That(fixture.Root.transform.localScale, Is.EqualTo(Vector3.one));
        Assert.That(fixture.Body.transform.localScale, Is.EqualTo(new Vector3(1.8f, 2.4f, 0.5f)));

        for (int x = -1; x <= 1; x += 2)
        for (int y = -1; y <= 1; y += 2)
        for (int z = -1; z <= 1; z += 2)
        {
            Vector3 point = bounds.center + Vector3.Scale(bounds.extents, new Vector3(x, y, z));
            Vector3 viewport = camera.WorldToViewportPoint(point);
            Assert.That(viewport.z, Is.GreaterThan(camera.nearClipPlane));
            Assert.That(viewport.x, Is.InRange(-0.0001f, 1.0001f));
            Assert.That(viewport.y, Is.InRange(0.2f - 0.0001f, 0.85f + 0.0001f),
                "Every body corner must clear the Flutter top controls and composer.");
        }
    }

    [TestCase("head")]
    [TestCase("upper_body")]
    [TestCase("three_quarter")]
    public void HomeCloseupPresetsUseAuthoredLensAndKeepExistingPose(string mode)
    {
        using var fixture = new HomeRoomFramingFixture(390f / 844f);
        fixture.Call("SetHomeViewReference", fixture.Reference);
        fixture.Call("FrameNow");
        fixture.Call("SetFramingMode", mode);
        Assert.That(fixture.Camera.fieldOfView,
            Is.EqualTo(HomeRoomFramingFixture.AuthoredFieldOfView).Within(0.0001f));
        Vector3 closeupPosition = fixture.Camera.transform.position;
        Quaternion closeupRotation = fixture.Camera.transform.rotation;
        fixture.Call("SetHomeViewReference", (object)null);
        fixture.Call("FrameNow");
        Assert.That(Vector3.Distance(fixture.Camera.transform.position, closeupPosition), Is.LessThan(0.0001f));
        Assert.That(Quaternion.Angle(fixture.Camera.transform.rotation, closeupRotation), Is.LessThan(0.001f));
    }

    [Test]
    public void HomeLensRestoresForLiveAndReferenceRemovalWithoutChangingUnboundFraming()
    {
        using var fixture = new HomeRoomFramingFixture(390f / 844f);
        Vector3 unboundPosition = fixture.Camera.transform.position;
        Assert.That(unboundPosition.z, Is.GreaterThan(3.9f));
        fixture.Call("SetHomeViewReference", fixture.Reference);
        fixture.Call("FrameNow");
        float fittedFieldOfView = fixture.Camera.fieldOfView;
        fixture.Call("SetHomeViewReference", fixture.Reference);
        fixture.Call("FrameNow");
        Assert.That(fixture.Camera.fieldOfView, Is.EqualTo(fittedFieldOfView).Within(0.0001f),
            "Rebinding Home must not capture its adjusted lens as the authored lens.");

        fixture.Call("SetFramingMode", "hero_full_body");
        Assert.That(fixture.Camera.fieldOfView, Is.GreaterThan(HomeRoomFramingFixture.AuthoredFieldOfView));
        fixture.Call("SetHomeViewReference", (object)null);
        Assert.That(fixture.Camera.fieldOfView,
            Is.EqualTo(HomeRoomFramingFixture.AuthoredFieldOfView).Within(0.0001f));
        fixture.Call("FrameNow");
        Assert.That(Vector3.Distance(fixture.Camera.transform.position, unboundPosition), Is.LessThan(0.0001f));
    }

    [Test]
    public void DisabledHomeFramingReleasesLensAndRecoversAfterWorldCameraReturn()
    {
        using var fixture = new HomeRoomFramingFixture(390f / 844f);
        fixture.Call("SetHomeViewReference", fixture.Reference);
        fixture.Call("FrameNow");
        float fittedFieldOfView = fixture.Camera.fieldOfView;
        ((Behaviour)fixture.Framing).enabled = false;
        Assert.That(fixture.Camera.fieldOfView,
            Is.EqualTo(HomeRoomFramingFixture.AuthoredFieldOfView).Within(0.0001f));
        fixture.Camera.fieldOfView = 52f;
        fixture.Call("AdvanceFraming", 1f);
        Assert.That(fixture.Camera.fieldOfView, Is.EqualTo(52f), "World camera owns the lens while Home is disabled.");
        fixture.Camera.fieldOfView = fittedFieldOfView;
        ((Behaviour)fixture.Framing).enabled = true;
        Assert.That(fixture.Camera.fieldOfView, Is.EqualTo(fittedFieldOfView).Within(0.0001f));
        UnityEngine.Object.DestroyImmediate(fixture.Reference.gameObject);
        fixture.Call("FrameNow");
        Assert.That(fixture.Camera.fieldOfView,
            Is.EqualTo(HomeRoomFramingFixture.AuthoredFieldOfView).Within(0.0001f));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void HiddenOrCulledHomeRoomReleasesLensWithReferenceStillBound(bool cullLayer)
    {
        using var fixture = new HomeRoomFramingFixture(390f / 844f);
        fixture.AlignHome();
        Assert.That(fixture.Camera.fieldOfView, Is.GreaterThan(HomeRoomFramingFixture.AuthoredFieldOfView));
        if (cullLayer)
            fixture.Camera.cullingMask &= ~(1 << fixture.EnvironmentRenderer.gameObject.layer);
        else
            fixture.EnvironmentRoot.gameObject.SetActive(false);

        fixture.Call("FrameNow");
        Assert.That(fixture.BoundReference, Is.SameAs(fixture.Reference));
        Assert.That(fixture.Camera.fieldOfView,
            Is.EqualTo(HomeRoomFramingFixture.AuthoredFieldOfView).Within(0.0001f));
        Assert.That(fixture.Camera.transform.position.z, Is.GreaterThan(3.9f));

        fixture.Camera.cullingMask = ~0;
        fixture.EnvironmentRoot.gameObject.SetActive(true);
        fixture.Call("FrameNow");
        Assert.That(fixture.Camera.fieldOfView, Is.GreaterThan(HomeRoomFramingFixture.AuthoredFieldOfView));
    }

    [Test]
    public void WindowsDesktopPetCameraStateDoesNotFitRetainedHomeReference()
    {
        using var fixture = new HomeRoomFramingFixture(390f / 844f);
        fixture.AlignHome();
        // WindowsDesktopPetPresentationController.ConfigureTargetCamera keeps
        // the main camera but isolates layer 31 on transparent RGBA.
        fixture.Root.layer = 31;
        fixture.Body.gameObject.layer = 31;
        fixture.Camera.clearFlags = CameraClearFlags.SolidColor;
        fixture.Camera.backgroundColor = Color.clear;
        fixture.Camera.cullingMask = 1 << 31;
        fixture.Call("FrameNow");
        Assert.That(fixture.BoundReference, Is.SameAs(fixture.Reference));
        Assert.That(fixture.EnvironmentRoot.gameObject.activeInHierarchy, Is.True);
        Assert.That(fixture.Camera.fieldOfView,
            Is.EqualTo(HomeRoomFramingFixture.AuthoredFieldOfView).Within(0.0001f));

        // The desktop controller subsequently owns its authored 28-degree lens.
        fixture.Camera.fieldOfView = 28f;
        fixture.Call("FrameNow");
        Assert.That(fixture.Camera.fieldOfView, Is.EqualTo(28f));
        Assert.That(fixture.Camera.transform.position.z, Is.GreaterThan(3.9f));
        fixture.Camera.cullingMask = ~0;
        fixture.Call("FrameNow");
        Assert.That(fixture.Camera.fieldOfView, Is.EqualTo(28f),
            "A transparent camera must remain isolated even while its mask is being restored.");
    }

    [Test]
    public void PortalAcquireAndReleaseUseActualMapBindingWithoutChangingPortalLens()
    {
        if (SystemInfo.graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Null)
            Assert.Ignore("Acquiring the real portal requires a graphics device.");
        using var fixture = new HomeRoomFramingFixture(390f / 844f);
        Type receiverType = Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true);
        Component receiver = fixture.Root.AddComponent(receiverType);
        receiverType.GetField("avatarRoot", BindingFlags.Instance | BindingFlags.NonPublic)
            .SetValue(receiver, fixture.Root.transform);
        fixture.Map.GetType().GetMethod("SetWorldActive").Invoke(fixture.Map, new object[] { false });
        Assert.That(fixture.BoundReference, Is.SameAs(fixture.Reference));
        float homeFieldOfView = fixture.Camera.fieldOfView;
        Assert.That(homeFieldOfView, Is.GreaterThan(HomeRoomFramingFixture.AuthoredFieldOfView));

        Type portalType = Type.GetType("Maaso.Avatar.CompanionPortalCaptureController, Assembly-CSharp", true);
        Component portal = new GameObject("Real desktop portal").AddComponent(portalType);
        MethodInfo command = portalType.GetMethod("OnAvatarPortalCommand");
        try
        {
            // DesktopUnitySidecarBridge.Update dispatches this same command.
            command.Invoke(portal, new object[] {
                "{\"method\":\"acquire\",\"generation\":1,\"profile\":\"compactLow\",\"targetFps\":24}" });
            Assert.That(portalType.GetProperty("IsAcquired").GetValue(portal), Is.True);
            Camera portalCamera = (Camera)portalType.GetField("portalCamera",
                BindingFlags.Instance | BindingFlags.NonPublic).GetValue(portal);
            fixture.AlignHome();
            Assert.That(fixture.BoundReference, Is.SameAs(fixture.Reference),
                "The actual alignment path retains the room reference during portal capture.");
            Assert.That(fixture.EnvironmentRoot.gameObject.activeInHierarchy, Is.True);
            Assert.That(fixture.Camera.cullingMask & (1 << fixture.Body.gameObject.layer), Is.Zero);
            Assert.That(fixture.Camera.fieldOfView,
                Is.EqualTo(HomeRoomFramingFixture.AuthoredFieldOfView).Within(0.0001f));
            Assert.That(portalCamera.fieldOfView, Is.EqualTo(28f));
            Assert.That(portalCamera.backgroundColor.a, Is.Zero);

            command.Invoke(portal, new object[] { "{\"method\":\"release\",\"generation\":1}" });
            fixture.Call("FrameNow");
            Assert.That(fixture.BoundReference, Is.SameAs(fixture.Reference));
            Assert.That(fixture.Camera.fieldOfView, Is.EqualTo(homeFieldOfView).Within(0.0001f));
            Assert.That(fixture.Camera.transform.position.z, Is.LessThanOrEqualTo(3.2001f));

            command.Invoke(portal, new object[] {
                "{\"method\":\"acquire\",\"generation\":2,\"profile\":\"compactHigh\",\"targetFps\":30," +
                "\"includeWorld\":true,\"viewportWidth\":390,\"viewportHeight\":844}" });
            Camera sceneCamera = (Camera)portalType.GetField("portalCamera",
                BindingFlags.Instance | BindingFlags.NonPublic).GetValue(portal);
            fixture.AlignHome();
            Assert.That(sceneCamera, Is.SameAs(fixture.Camera));
            Assert.That(fixture.Camera.cullingMask & (1 << fixture.Body.gameObject.layer), Is.Not.Zero);
            Assert.That(fixture.Camera.cullingMask & (1 << fixture.EnvironmentRenderer.gameObject.layer), Is.Not.Zero);
            Assert.That(fixture.Camera.fieldOfView, Is.EqualTo(homeFieldOfView).Within(0.0001f),
                "The actual Home scene lease must retain the safe room lens, not the avatar-only 28-degree lens.");
            Assert.That(fixture.Camera.transform.position.z, Is.LessThanOrEqualTo(3.2001f));
            Assert.That(sceneCamera.targetTexture.width, Is.EqualTo(390));
            Assert.That(sceneCamera.targetTexture.height, Is.EqualTo(844));
        }
        finally
        {
            portalType.GetMethod("Release").Invoke(portal, new object[] { 0 });
            UnityEngine.Object.DestroyImmediate(portal.gameObject);
        }
    }

    private sealed class HomeRoomFramingFixture : IDisposable
    {
        public const float AuthoredFieldOfView = 35f;
        public readonly Type Type;
        public readonly GameObject Root;
        public readonly Renderer Body;
        public readonly Camera Camera;
        public readonly Component Framing;
        public readonly Transform Reference;
        public readonly Component Map;
        public readonly Transform EnvironmentRoot;
        public readonly Renderer EnvironmentRenderer;
        public Transform BoundReference => (Transform)Type.GetField("homeViewReference",
            BindingFlags.Instance | BindingFlags.NonPublic).GetValue(Framing);

        public HomeRoomFramingFixture(float aspect)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Type = System.Type.GetType(ComponentTypeName);
            Assert.That(Type, Is.Not.Null);
            Root = new GameObject("HomeRoomAvatar");
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            body.transform.SetParent(Root.transform, false);
            body.transform.localPosition = new Vector3(0f, 1.2f, 0f);
            body.transform.localScale = new Vector3(1.8f, 2.4f, 0.5f);
            Body = body.GetComponent<Renderer>();
            Camera = new GameObject("HomeRoomCamera") { tag = "MainCamera" }.AddComponent<Camera>();
            Camera.fieldOfView = AuthoredFieldOfView;
            Camera.aspect = aspect;
            Camera.clearFlags = CameraClearFlags.SolidColor;
            Camera.backgroundColor = Color.gray;
            Framing = Camera.gameObject.AddComponent(Type);
            System.Type mapType = System.Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true);
            Map = (Component)mapType.GetMethod("BuildDefaultMap").Invoke(null,
                new object[] { new GameObject("Home room map") });
            Reference = (Transform)mapType.GetProperty("HomeCameraReference").GetValue(Map);
            EnvironmentRoot = (Transform)mapType.GetProperty("PersistentEnvironmentRoot").GetValue(Map);
            GameObject roomSurface = GameObject.CreatePrimitive(PrimitiveType.Cube);
            roomSurface.name = "Home room surface";
            roomSurface.layer = 28;
            roomSurface.transform.SetParent(EnvironmentRoot, false);
            roomSurface.transform.localPosition = new Vector3(3.9f, 1.2f, 0f);
            EnvironmentRenderer = roomSurface.GetComponent<Renderer>();
            Type.GetProperty("TargetRoot").SetValue(Framing, Root.transform);
            Call("FrameNow");
        }

        public void Call(string method, params object[] arguments) =>
            Type.GetMethod(method).Invoke(Framing, arguments);

        public void AlignHome() => Assert.That(Map.GetType().GetMethod("AlignHomeAvatar")
            .Invoke(Map, new object[] { Root.transform }), Is.True);

        public void Dispose()
        {
            UnityEngine.Object.DestroyImmediate(Camera.gameObject);
            UnityEngine.Object.DestroyImmediate(Root);
            UnityEngine.Object.DestroyImmediate(Map.gameObject);
        }
    }

    [Test]
    public void CompanionSceneMainCameraUsesFrontFullBodyFraming()
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Assert.That(scene.isLoaded, Is.True);

        Camera camera = Camera.main;
        Assert.That(camera, Is.Not.Null);

        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null, "Front full-body camera component should exist.");
        Assert.That(
            camera.GetComponent(componentType),
            Is.Not.Null,
            "Main Camera should keep the avatar framed from the front at runtime.");
    }

    [Test]
    public void CalculatePosePlacesCameraInFrontAndFitsFullBodyBounds()
    {
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null, "Front full-body camera component should exist.");

        MethodInfo calculatePose = componentType.GetMethod(
            "CalculatePose",
            BindingFlags.Public | BindingFlags.Static,
            null,
            new[]
            {
                typeof(Bounds),
                typeof(Vector3),
                typeof(Vector3),
                typeof(float),
                typeof(float),
                typeof(float),
                typeof(float),
            },
            null);
        Assert.That(calculatePose, Is.Not.Null);

        var bounds = new Bounds(new Vector3(0f, 1f, 0f), new Vector3(1f, 2f, 0.5f));
        object pose = calculatePose.Invoke(
            null,
            new object[] { bounds, Vector3.forward, Vector3.up, 45f, 9f / 16f, 1.1f, 0.25f });

        Type poseType = pose.GetType();
        var position = (Vector3)poseType.GetProperty("Position").GetValue(pose);
        var rotation = (Quaternion)poseType.GetProperty("Rotation").GetValue(pose);

        Assert.That(position.z, Is.GreaterThan(bounds.center.z), "Camera should stay on the avatar's front side.");

        Vector3 viewDirection = rotation * Vector3.forward;
        Vector3 directionToAvatar = (bounds.center - position).normalized;
        Assert.That(Vector3.Dot(viewDirection, directionToAvatar), Is.GreaterThan(0.999f));

        float distance = Vector3.Distance(position, bounds.center);
        float visibleHalfHeight = Mathf.Tan(45f * Mathf.Deg2Rad * 0.5f) * distance;
        Assert.That(visibleHalfHeight, Is.GreaterThanOrEqualTo(bounds.extents.y * 1.1f));
    }

    [Test]
    public void CalculatePoseFitsFullBodyInsideFlutterSafeViewport()
    {
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null, "Front full-body camera component should exist.");

        MethodInfo calculatePose = componentType.GetMethod(
            "CalculatePose",
            BindingFlags.Public | BindingFlags.Static,
            null,
            new[]
            {
                typeof(Bounds),
                typeof(Vector3),
                typeof(Vector3),
                typeof(float),
                typeof(float),
                typeof(float),
                typeof(float),
                typeof(float),
                typeof(float),
            },
            null);
        Assert.That(calculatePose, Is.Not.Null);

        const float verticalFieldOfView = 37.5f;
        const float aspect = 9f / 16f;
        const float padding = 1f;
        const float topSafeViewport = 0.15f;
        const float bottomSafeViewport = 0.2f;
        var bounds = new Bounds(new Vector3(0f, 1f, 0f), new Vector3(1f, 2f, 0.5f));

        object pose = calculatePose.Invoke(
            null,
            new object[]
            {
                bounds,
                Vector3.forward,
                Vector3.up,
                verticalFieldOfView,
                aspect,
                padding,
                0.25f,
                topSafeViewport,
                bottomSafeViewport,
            });

        Type poseType = pose.GetType();
        var position = (Vector3)poseType.GetProperty("Position").GetValue(pose);
        var rotation = (Quaternion)poseType.GetProperty("Rotation").GetValue(pose);

        float bottomViewportY = CalculateViewportY(
            position,
            rotation,
            bounds.center - Vector3.up * bounds.extents.y,
            verticalFieldOfView);
        float topViewportY = CalculateViewportY(
            position,
            rotation,
            bounds.center + Vector3.up * bounds.extents.y,
            verticalFieldOfView);

        Assert.That(
            bottomViewportY,
            Is.GreaterThanOrEqualTo(bottomSafeViewport - 0.001f),
            "Avatar feet should stay above the Flutter input bar.");
        Assert.That(
            topViewportY,
            Is.LessThanOrEqualTo(1f - topSafeViewport + 0.001f),
            "Avatar head should stay below the top controls.");
    }

    [Test]
    public void ManualAvatarMotionKeepsCameraFixedUntilFullBodyFramingResumes()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null, "Front full-body camera component should exist.");

        var root = new GameObject("AvatarRoot");
        GameObject body = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        var cameraObject = new GameObject("Main Camera");

        try
        {
            body.transform.SetParent(root.transform, false);
            body.transform.localPosition = new Vector3(0f, 1f, 0f);
            cameraObject.tag = "MainCamera";
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.fieldOfView = 37.5f;
            Component framing = cameraObject.AddComponent(componentType);
            componentType.GetProperty("TargetRoot")?.SetValue(framing, root.transform);
            componentType.GetMethod("FrameNow")?.Invoke(framing, Array.Empty<object>());
            Vector3 initialCameraPosition = cameraObject.transform.position;

            componentType.GetMethod("SetFramingMode")?.Invoke(
                framing,
                new object[] { "manual_avatar_motion" });
            root.transform.position += Vector3.right * 3f;
            InvokeReceiverMethod(componentType, framing, "LateUpdate");

            Assert.That(
                cameraObject.transform.position.x,
                Is.EqualTo(initialCameraPosition.x).Within(0.001f),
                "Login entrance movement needs a fixed camera so the avatar can enter from off-screen.");

            componentType.GetMethod("SetFramingMode")?.Invoke(
                framing,
                new object[] { "hero_full_body" });

            Assert.That(
                cameraObject.transform.position.x,
                Is.GreaterThan(initialCameraPosition.x + 1f),
                "Full-body framing should resume normal target tracking after the entrance choreography.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(root);
        }
    }

    [Test]
    public void CompanionScenePhoneFramingCentersVisibleIdleAboveFlutterInput()
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Assert.That(scene.isLoaded, Is.True);
        PrepareDesignedIdle();

        Camera camera = Camera.main;
        Assert.That(camera, Is.Not.Null);

        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null, "Front full-body camera component should exist.");

        Component framing = camera.GetComponent(componentType);
        Assert.That(framing, Is.Not.Null);

        Rect pixelBounds = CaptureVisiblePixelBounds(camera, componentType, framing, 0.18f, 0.18f);

        Assert.That(
            pixelBounds.center.x,
            Is.EqualTo(0.5f).Within(0.06f),
            "Visible avatar should be horizontally centered in the Flutter viewport.");
        Assert.That(
            pixelBounds.center.y,
            Is.InRange(0.45f, 0.6f),
            "Visible avatar should sit near the center of the usable area, not down behind the composer.");
        Assert.That(
            pixelBounds.yMin,
            Is.GreaterThanOrEqualTo(0.14f),
            "Visible avatar feet should clear the Flutter input bar on a phone viewport.");
        Assert.That(
            pixelBounds.yMax,
            Is.LessThanOrEqualTo(0.86f),
            "Visible avatar head should stay below the top controls on a phone viewport.");
        Assert.That(
            pixelBounds.height,
            Is.GreaterThanOrEqualTo(0.58f),
            "Visible avatar should be large enough for the main home screen.");
    }

    [Test]
    public void RuntimeHomeMapKeepsAvatarFeetVisibleOnIPhonePortraitViewport()
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Assert.That(scene.isLoaded, Is.True);
        PrepareDesignedIdle();

        Type receiverType = Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
        Assert.That(receiverType, Is.Not.Null);
        Component receiver = FindSceneComponent(receiverType);
        Assert.That(receiver, Is.Not.Null);
        Transform avatarRoot = receiverType.GetProperty("ActiveAvatarRoot")?.GetValue(receiver) as Transform;
        Assert.That(avatarRoot, Is.Not.Null);

        Camera camera = Camera.main;
        Assert.That(camera, Is.Not.Null);
        Type componentType = Type.GetType(ComponentTypeName);
        Assert.That(componentType, Is.Not.Null);
        Component framing = camera.GetComponent(componentType);
        Assert.That(framing, Is.Not.Null);
        camera.scene = scene;
        camera.aspect = 393f / 852f;

        GameObject mapPrefab = Resources.Load<GameObject>("PersonalSpaceMap");
        Assert.That(mapPrefab, Is.Not.Null);
        GameObject mapRoot = UnityEngine.Object.Instantiate(mapPrefab);
        mapRoot.name = "RuntimeHomeMap-Test";
        try
        {
            Type mapType = Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp");
            Assert.That(mapType, Is.Not.Null);
            Component map = mapRoot.GetComponent(mapType);
            Assert.That(map, Is.Not.Null);
            mapType.GetMethod("SetWorldActive")?.Invoke(map, new object[] { false });
            object aligned = mapType.GetMethod("AlignHomeAvatar")?.Invoke(
                map,
                new object[] { avatarRoot });
            Assert.That(aligned, Is.EqualTo(true));

            componentType.GetProperty("TargetRoot")?.SetValue(framing, avatarRoot);
            Rect pixelBounds = CaptureAvatarPixelBoundsAgainstRenderedMap(
                camera,
                avatarRoot,
                componentType,
                framing,
                0.18f,
                0.18f);

            Assert.That(camera.transform.position.z, Is.LessThanOrEqualTo(3.2001f),
                "The Home camera must stay in front of the rear bookcase, including on a narrow phone.");
            Renderer bookshelf = Array.Find(mapRoot.GetComponentsInChildren<Renderer>(true),
                value => value.name == "V4_Bookshelf_Baked");
            Assert.That(bookshelf, Is.Not.Null, "The actual V4 baked bookcase must participate in this regression.");
            Assert.That(bookshelf.bounds.min.z - camera.transform.position.z, Is.GreaterThan(.25f),
                "The entire bookcase must remain behind the Home camera with physical clearance.");

            // A temporary collider queries the imported triangles, rather than
            // assuming the renderer AABB is solid. It is never part of gameplay.
            MeshFilter shelfMesh = bookshelf.GetComponent<MeshFilter>();
            Assert.That(shelfMesh, Is.Not.Null);
            GameObject probe = new GameObject("Home bookcase geometry regression");
            bool oldHitBackfaces = Physics.queriesHitBackfaces;
            try
            {
                probe.transform.SetParent(bookshelf.transform, false);
                MeshCollider geometry = probe.AddComponent<MeshCollider>();
                geometry.sharedMesh = shelfMesh.sharedMesh;
                Physics.queriesHitBackfaces = true;
                Physics.SyncTransforms();
                int oldBlockedRays = 0;
                int homeBlockedRays = 0;
                Bounds shelfBounds = bookshelf.bounds;
                for (int column = 1; column <= 9; column++)
                for (int row = 1; row <= 9; row++)
                {
                    float x = Mathf.Lerp(shelfBounds.min.x, shelfBounds.max.x, column / 10f);
                    float y = Mathf.Lerp(shelfBounds.min.y, shelfBounds.max.y, row / 10f);
                    if (geometry.Raycast(new Ray(new Vector3(x, y, 3.883f), Vector3.back), out _, 3.883f))
                        oldBlockedRays++;
                    if (geometry.Raycast(new Ray(new Vector3(x, y, camera.transform.position.z), Vector3.back),
                        out _, camera.transform.position.z))
                        homeBlockedRays++;
                }
                TestContext.Out.WriteLine($"Bookcase bounds {shelfBounds}; Home camera {camera.transform.position}; " +
                    $"old z=3.883 blocked rays={oldBlockedRays}/81, current blocked rays={homeBlockedRays}/81.");
                Assert.That(oldBlockedRays, Is.GreaterThan(0),
                    "The old camera plane must reproduce actual bookcase geometry in front of the avatar.");
                Assert.That(homeBlockedRays, Is.Zero,
                    "The corrected Home camera must have no bookcase triangles between it and the avatar plane.");
            }
            finally
            {
                Physics.queriesHitBackfaces = oldHitBackfaces;
                UnityEngine.Object.DestroyImmediate(probe);
            }

            Assert.That(
                pixelBounds.yMin,
                Is.InRange(0.14f, 0.3f),
                "Avatar feet should remain visible above the Flutter composer after the persistent map grounds the avatar.");
            Assert.That(
                pixelBounds.yMax,
                Is.LessThanOrEqualTo(0.86f),
                "Avatar head should remain below the Flutter top controls.");
            Animator humanoid = avatarRoot.GetComponentInChildren<Animator>(true);
            Assert.That(humanoid, Is.Not.Null);
            Assert.That(humanoid.isHuman, Is.True);
            float footY = float.PositiveInfinity;
            foreach (HumanBodyBones bone in new[]
                { HumanBodyBones.Head, HumanBodyBones.LeftFoot, HumanBodyBones.RightFoot })
            {
                Transform joint = humanoid.GetBoneTransform(bone);
                Assert.That(joint, Is.Not.Null, bone.ToString());
                Vector3 projected = camera.WorldToViewportPoint(joint.position);
                Assert.That(projected.z, Is.GreaterThan(camera.nearClipPlane), bone.ToString());
                Assert.That(projected.y, Is.InRange(0.14f, 0.86f), bone.ToString());
                Assert.That(projected.x, Is.InRange(pixelBounds.xMin - .01f, pixelBounds.xMax + .01f),
                    "The rendered silhouette must retain " + bone);
                Assert.That(projected.y, Is.InRange(pixelBounds.yMin - .01f, pixelBounds.yMax + .01f),
                    "The rendered silhouette must retain " + bone);
                if (bone != HumanBodyBones.Head) footY = Mathf.Min(footY, projected.y);
            }
            float headY = camera.WorldToViewportPoint(
                humanoid.GetBoneTransform(HumanBodyBones.Head).position).y;
            Assert.That(pixelBounds.height, Is.GreaterThanOrEqualTo(headY - footY),
                "Visible pixels must span the actual head-to-foot extent, including both feet.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(mapRoot);
        }
    }

    [Test]
    public void BundledDaySkyUsesTextureFreeMobileShaderAndRuntimeLightingOwnsCamera()
    {
        Material material = AssetDatabase.LoadAssetAtPath<Material>(
            DaySkyMaterialPath);
        Assert.That(material, Is.Not.Null, DaySkyMaterialPath);
        Assert.That(material.shader.name, Is.EqualTo("Maaso/Mobile Day Sky"));
        Assert.That(
            material.HasProperty("_Tex"),
            Is.False,
            "Mobile sky rendering must not rely on platform HDR cubemap import.");
        Assert.That(
            AssetDatabase.GetDependencies(DaySkyMaterialPath, true),
            Has.None.EqualTo(LegacyHdrPath),
            "The material must not retain a hidden serialized reference that " +
            "still packages the HDR cubemap on iOS.");
        Assert.That(
            AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(LegacyHdrPath),
            Is.Null,
            "The retired HDR cubemap must not remain in the Unity project.");
        Color zenith = material.GetColor("_ZenithColor");
        Color horizon = material.GetColor("_HorizonColor");
        Assert.That(zenith.b, Is.GreaterThan(zenith.r));
        Assert.That(horizon.b, Is.GreaterThan(horizon.r));
        Assert.That(
            material.HasProperty("_CloudColor"),
            Is.False,
            "The mobile sky must remain a plain blue gradient without fake clouds.");
        string shaderSource = File.ReadAllText(
            AssetDatabase.GetAssetPath(material.shader));
        Assert.That(
            shaderSource,
            Does.Not.Contain("Cloud"),
            "The mobile sky shader must not draw procedural cloud shapes.");

        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
        Assert.That(scene.isLoaded, Is.True, ScenePath);
        Camera camera = Camera.main;
        Assert.That(camera, Is.Not.Null, ScenePath);
        Type lightingType = Type.GetType(
            "Maaso.Avatar.UnityWorldLightingController, Assembly-CSharp");
        Assert.That(lightingType, Is.Not.Null);
        Assert.That(camera.GetComponent(lightingType), Is.Not.Null);
    }

    [Test]
    public void CompanionSceneIsFirstEnabledBuildScene()
    {
        EditorBuildSettingsScene[] scenes = EditorBuildSettings.scenes;

        Assert.That(scenes, Is.Not.Empty);
        Assert.That(scenes[0].enabled, Is.True);
        Assert.That(scenes[0].path, Is.EqualTo(ScenePath));
    }

    [Test]
    public void UnitySplashScreenAndLogoAreDisabled()
    {
        string settings = File.ReadAllText("ProjectSettings/ProjectSettings.asset");

        Assert.That(settings, Does.Contain("m_ShowUnitySplashScreen: 0"));
        Assert.That(settings, Does.Contain("m_ShowUnitySplashLogo: 0"));
    }

    [Test]
    public void LegacySampleSceneIsRemovedFromUnityProject()
    {
        string settings = File.ReadAllText("ProjectSettings/ProjectSettings.asset");

        Assert.That(File.Exists("Assets/Scenes/SampleScene.unity"), Is.False);
        Assert.That(settings, Does.Contain("templateDefaultScene: " + ScenePath));
        Assert.That(settings, Does.Not.Contain("Assets/Scenes/SampleScene.unity"));
    }

    private static bool TryGetRendererBounds(Transform root, out Bounds bounds)
    {
        bounds = default;
        Renderer[] renderers = root.GetComponentsInChildren<Renderer>(false);
        bool hasBounds = false;

        foreach (Renderer renderer in renderers)
        {
            if (renderer == null || !renderer.enabled)
            {
                continue;
            }

            if (!hasBounds)
            {
                bounds = renderer.bounds;
                hasBounds = true;
            }
            else
            {
                bounds.Encapsulate(renderer.bounds);
            }
        }

        return hasBounds;
    }

    private static void PrepareDesignedIdle()
    {
        Type receiverType = Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
        if (receiverType == null)
        {
            return;
        }

        Component receiver = FindSceneComponent(receiverType);
        if (receiver == null)
        {
            return;
        }

        InvokeReceiverMethod(receiverType, receiver, "EnsureAvatar");
        // This fixture is the local owner. Match Flutter's visibility grant
        // before LateUpdate applies the production ownership mask.
        MethodInfo command = receiverType.GetMethod("OnFlutterCommand");
        Assert.That(command, Is.Not.Null);
        command.Invoke(receiver, new object[]
        {
            "{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}"
        });
        MethodInfo tryStartDesignedIdle = receiverType.GetMethod(
            "TryStartDesignedIdle",
            BindingFlags.NonPublic | BindingFlags.Instance,
            null,
            Type.EmptyTypes,
            null);
        tryStartDesignedIdle?.Invoke(receiver, Array.Empty<object>());
        SampleIdleFrame(receiverType, receiver);
        InvokeReceiverMethod(receiverType, receiver, "LateUpdate");

        Camera camera = Camera.main;
        Type framingType = Type.GetType(ComponentTypeName);
        Component framing = camera != null ? camera.GetComponent(framingType) : null;
        PropertyInfo targetRoot = framingType?.GetProperty("TargetRoot");
        if (framing != null && targetRoot != null)
        {
            targetRoot.SetValue(framing, targetRoot.GetValue(framing));
        }
    }

    private static Component FindSceneComponent(Type type)
    {
        MonoBehaviour[] behaviours =
            UnityEngine.Object.FindObjectsByType<MonoBehaviour>(
                FindObjectsInactive.Exclude);

        for (int i = 0; i < behaviours.Length; i++)
        {
            MonoBehaviour behaviour = behaviours[i];
            if (behaviour != null && behaviour.GetType() == type)
            {
                return behaviour;
            }
        }

        return null;
    }

    private static void SampleIdleFrame(Type receiverType, Component receiver)
    {
        FieldInfo animatorField = receiverType.GetField(
            "animator",
            BindingFlags.NonPublic | BindingFlags.Instance);
        FieldInfo idleNameField = receiverType.GetField(
            "designedIdleStateName",
            BindingFlags.NonPublic | BindingFlags.Instance);
        var animator = animatorField?.GetValue(receiver) as Animator;
        if (animator == null || animator.runtimeAnimatorController == null)
        {
            return;
        }

        string stateName = idleNameField?.GetValue(receiver) as string;
        if (string.IsNullOrWhiteSpace(stateName))
        {
            stateName = "idle";
        }

        animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
        animator.Rebind();
        int stateHash = Animator.StringToHash(stateName);
        for (int layer = 0; layer < animator.layerCount; layer++)
        {
            if (animator.HasState(layer, stateHash))
            {
                animator.Play(stateHash, layer, 0.5f);
            }
        }

        animator.Update(1f / 60f);
    }

    private static void InvokeReceiverMethod(Type receiverType, Component receiver, string methodName)
    {
        MethodInfo method = receiverType.GetMethod(
            methodName,
            BindingFlags.NonPublic | BindingFlags.Instance);
        method?.Invoke(receiver, Array.Empty<object>());
    }

    private static Rect CaptureVisiblePixelBounds(
        Camera camera,
        Type componentType,
        Component framing,
        float topSafeViewport,
        float bottomSafeViewport)
    {
        const int width = 900;
        const int height = 1200;
        RenderTexture previousTarget = camera.targetTexture;
        CameraClearFlags previousClearFlags = camera.clearFlags;
        Color previousBackground = camera.backgroundColor;
        RenderTexture previousActive = RenderTexture.active;
        RenderTexture renderTexture = new(width, height, 24, RenderTextureFormat.ARGB32);
        Texture2D image = new(width, height, TextureFormat.RGBA32, false);

        try
        {
            camera.targetTexture = renderTexture;
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(0.96f, 0.95f, 0.93f, 1f);
            componentType.GetMethod("SetViewportSafeArea")?.Invoke(
                framing,
                new object[] { topSafeViewport, bottomSafeViewport });
            componentType.GetMethod("FrameNow")?.Invoke(framing, Array.Empty<object>());

            camera.Render();
            RenderTexture.active = renderTexture;
            image.ReadPixels(new Rect(0, 0, width, height), 0, 0);
            image.Apply();
            return CalculateVisiblePixelBounds(image);
        }
        finally
        {
            camera.targetTexture = previousTarget;
            camera.clearFlags = previousClearFlags;
            camera.backgroundColor = previousBackground;
            RenderTexture.active = previousActive;
            UnityEngine.Object.DestroyImmediate(image);
            UnityEngine.Object.DestroyImmediate(renderTexture);
        }
    }

    private static Rect CaptureAvatarPixelBoundsAgainstRenderedMap(
        Camera camera,
        Transform avatarRoot,
        Type componentType,
        Component framing,
        float topSafeViewport,
        float bottomSafeViewport)
    {
        const int width = 393;
        const int height = 852;
        RenderTexture previousTarget = camera.targetTexture;
        CameraClearFlags previousClearFlags = camera.clearFlags;
        Color previousBackground = camera.backgroundColor;
        RenderTexture previousActive = RenderTexture.active;
        RenderTexture renderTexture = new(width, height, 24, RenderTextureFormat.ARGB32);
        Texture2D withAvatar = new(width, height, TextureFormat.RGBA32, false);
        Texture2D withoutAvatar = new(width, height, TextureFormat.RGBA32, false);
        Renderer[] avatarRenderers = avatarRoot.GetComponentsInChildren<Renderer>(false);
        Type portraitType = Type.GetType("Maaso.Avatar.PortraitDepthOfField, Assembly-CSharp");
        Behaviour portrait = portraitType != null ? camera.GetComponent(portraitType) as Behaviour : null;
        bool portraitWasEnabled = portrait != null && portrait.enabled;
        bool[] rendererStates = new bool[avatarRenderers.Length];
        UnityEngine.Rendering.ShadowCastingMode[] shadowStates =
            new UnityEngine.Rendering.ShadowCastingMode[avatarRenderers.Length];

        try
        {
            // Pixel subtraction measures avatar framing only. Hiding the target
            // otherwise disables portrait blur and changes the entire backdrop.
            if (portrait != null) portrait.enabled = false;
            camera.targetTexture = renderTexture;
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(0.96f, 0.95f, 0.93f, 1f);
            componentType.GetMethod("SetViewportSafeArea")?.Invoke(
                framing,
                new object[] { topSafeViewport, bottomSafeViewport });
            componentType.GetMethod("FrameNow")?.Invoke(framing, Array.Empty<object>());

            for (int index = 0; index < avatarRenderers.Length; index++)
            {
                Renderer renderer = avatarRenderers[index];
                if (renderer == null)
                {
                    continue;
                }
                rendererStates[index] = renderer.enabled;
                shadowStates[index] = renderer.shadowCastingMode;
                renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            }

            camera.Render();
            ReadRenderTexture(renderTexture, withAvatar);

            for (int index = 0; index < avatarRenderers.Length; index++)
            {
                Renderer renderer = avatarRenderers[index];
                if (renderer != null)
                {
                    renderer.enabled = false;
                }
            }

            camera.Render();
            ReadRenderTexture(renderTexture, withoutAvatar);
            return CalculateDifferencePixelBounds(withAvatar, withoutAvatar);
        }
        finally
        {
            for (int index = 0; index < avatarRenderers.Length; index++)
            {
                if (avatarRenderers[index] != null)
                {
                    avatarRenderers[index].enabled = rendererStates[index];
                    avatarRenderers[index].shadowCastingMode = shadowStates[index];
                }
            }
            camera.targetTexture = previousTarget;
            camera.clearFlags = previousClearFlags;
            camera.backgroundColor = previousBackground;
            RenderTexture.active = previousActive;
            if (portrait != null) portrait.enabled = portraitWasEnabled;
            UnityEngine.Object.DestroyImmediate(withAvatar);
            UnityEngine.Object.DestroyImmediate(withoutAvatar);
            UnityEngine.Object.DestroyImmediate(renderTexture);
        }
    }

    private static void ReadRenderTexture(RenderTexture source, Texture2D destination)
    {
        RenderTexture.active = source;
        destination.ReadPixels(new Rect(0, 0, source.width, source.height), 0, 0);
        destination.Apply();
    }

    private static Rect CalculateDifferencePixelBounds(Texture2D foreground, Texture2D background)
    {
        const int tolerance = 10;
        Color32[] foregroundPixels = foreground.GetPixels32();
        Color32[] backgroundPixels = background.GetPixels32();
        int minX = foreground.width;
        int minY = foreground.height;
        int maxX = -1;
        int maxY = -1;

        for (int y = 0; y < foreground.height; y++)
        {
            for (int x = 0; x < foreground.width; x++)
            {
                int index = (y * foreground.width) + x;
                Color32 pixel = foregroundPixels[index];
                Color32 reference = backgroundPixels[index];
                if (Mathf.Abs(pixel.r - reference.r) <= tolerance &&
                    Mathf.Abs(pixel.g - reference.g) <= tolerance &&
                    Mathf.Abs(pixel.b - reference.b) <= tolerance)
                {
                    continue;
                }

                minX = Mathf.Min(minX, x);
                minY = Mathf.Min(minY, y);
                maxX = Mathf.Max(maxX, x);
                maxY = Mathf.Max(maxY, y);
            }
        }

        Assert.That(maxX, Is.GreaterThanOrEqualTo(minX), "Rendered avatar pixels should not be empty.");
        Assert.That(maxY, Is.GreaterThanOrEqualTo(minY), "Rendered avatar pixels should not be empty.");

        return Rect.MinMaxRect(
            (float)minX / foreground.width,
            (float)minY / foreground.height,
            (float)(maxX + 1) / foreground.width,
            (float)(maxY + 1) / foreground.height);
    }

    private static Rect CalculateVisiblePixelBounds(Texture2D image)
    {
        const int tolerance = 12;
        Color32[] pixels = image.GetPixels32();
        Color32 background = pixels[0];
        int minX = image.width;
        int minY = image.height;
        int maxX = -1;
        int maxY = -1;

        for (int y = 0; y < image.height; y++)
        {
            for (int x = 0; x < image.width; x++)
            {
                Color32 pixel = pixels[(y * image.width) + x];
                if (Mathf.Abs(pixel.r - background.r) <= tolerance &&
                    Mathf.Abs(pixel.g - background.g) <= tolerance &&
                    Mathf.Abs(pixel.b - background.b) <= tolerance)
                {
                    continue;
                }

                minX = Mathf.Min(minX, x);
                minY = Mathf.Min(minY, y);
                maxX = Mathf.Max(maxX, x);
                maxY = Mathf.Max(maxY, y);
            }
        }

        Assert.That(maxX, Is.GreaterThanOrEqualTo(minX), "Rendered avatar pixels should not be empty.");
        Assert.That(maxY, Is.GreaterThanOrEqualTo(minY), "Rendered avatar pixels should not be empty.");

        return Rect.MinMaxRect(
            (float)minX / image.width,
            (float)minY / image.height,
            (float)(maxX + 1) / image.width,
            (float)(maxY + 1) / image.height);
    }

    private static (float MinY, float MaxY) CalculateVerticalViewportRange(
        Bounds bounds,
        Vector3 cameraPosition,
        Quaternion cameraRotation,
        float verticalFieldOfView)
    {
        float minY = float.PositiveInfinity;
        float maxY = float.NegativeInfinity;
        Vector3 extents = bounds.extents;

        for (int x = -1; x <= 1; x += 2)
        {
            for (int y = -1; y <= 1; y += 2)
            {
                for (int z = -1; z <= 1; z += 2)
                {
                    Vector3 point = bounds.center + new Vector3(
                        extents.x * x,
                        extents.y * y,
                        extents.z * z);
                    float viewportY = CalculateViewportY(
                        cameraPosition,
                        cameraRotation,
                        point,
                        verticalFieldOfView);

                    minY = Mathf.Min(minY, viewportY);
                    maxY = Mathf.Max(maxY, viewportY);
                }
            }
        }

        return (minY, maxY);
    }

    private static float CalculateViewportY(
        Vector3 cameraPosition,
        Quaternion cameraRotation,
        Vector3 worldPoint,
        float verticalFieldOfView)
    {
        Vector3 cameraForward = cameraRotation * Vector3.forward;
        Vector3 cameraUp = cameraRotation * Vector3.up;
        Vector3 toPoint = worldPoint - cameraPosition;
        float depth = Vector3.Dot(toPoint, cameraForward);
        float halfHeightAtDepth = Mathf.Tan(verticalFieldOfView * Mathf.Deg2Rad * 0.5f) * depth;
        float normalizedY = Vector3.Dot(toPoint, cameraUp) / halfHeightAtDepth;
        return normalizedY * 0.5f + 0.5f;
    }
}
