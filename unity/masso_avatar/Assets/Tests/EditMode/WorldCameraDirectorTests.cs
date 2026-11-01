using System.Collections;
using System;
using System.Reflection;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;

public sealed class WorldCameraDirectorTests
{
    [SetUp]
    public void StartFromEmptyScene() =>
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

    [TearDown]
    public void RemoveFixtureScene() =>
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

    [TestCase(0.5625f)]
    [TestCase(1f)]
    [TestCase(1.777778f)]
    public void PersonalSpaceOverviewKeepsCoastalWindowInFrontOfCamera(float aspect)
    {
        var cameraObject = new GameObject("CoastalRoomOverviewCamera");
        try
        {
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.fieldOfView = 51f;
            camera.aspect = aspect;
            object pose = WorldType("WorldCameraDirector")
                .GetMethod("CalculatePersonalSpacePose", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, new object[] { Vector3.zero, Vector3.forward });
            camera.transform.SetPositionAndRotation(
                Property<Vector3>(pose, "Position"), Property<Quaternion>(pose, "Rotation"));
            Assert.That(camera.transform.position.z, Is.GreaterThan(0f));
            Assert.That(camera.transform.position.y, Is.EqualTo(1.3f).Within(0.001f));
            Assert.That(camera.transform.position.z, Is.EqualTo(3.2f).Within(0.001f));
            Assert.That(camera.transform.forward.z, Is.LessThan(0f));
            Vector3 owner = camera.WorldToViewportPoint(Vector3.up);
            Vector3 window = camera.WorldToViewportPoint(new Vector3(0f, 1.95f, -4.8f));
            Vector3 coast = camera.WorldToViewportPoint(new Vector3(0f, 1.95f, -5.92f));
            Assert.That(coast.z, Is.GreaterThan(window.z));
            Assert.That(window.z, Is.GreaterThan(owner.z));
            Assert.That(coast.x, Is.InRange(0.42f, 0.58f));
            Assert.That(coast.y, Is.InRange(0.46f, 0.94f),
                "The window view should remain above the owner, not behind the camera.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
        }
    }

    [TestCase(0f, 0f, 390f / 844f)]
    [TestCase(-3.5f, -3.5f, 390f / 844f)]
    [TestCase(3.5f, -3.5f, 390f / 844f)]
    [TestCase(-3.5f, 3.5f, 390f / 844f)]
    [TestCase(3.5f, 3.5f, 390f / 844f)]
    [TestCase(0f, 3.5f, 390f / 844f)]
    [TestCase(0f, -3.5f, 390f / 844f)]
    [TestCase(-3.5f, 3.5f, 16f / 9f)]
    [TestCase(3.5f, -3.5f, 16f / 9f)]
    public void PersonalSpaceRuntimeStaysInsideAtEyeLevelAndFramesOwner(float x, float z, float aspect)
    {
        var mapRoot = new GameObject("IndoorCameraMap");
        var cameraRoot = new GameObject("IndoorCamera");
        var owner = new GameObject("IndoorCameraOwner");
        try
        {
            object map = WorldType("PersistentWorldMapController")
                .GetMethod("BuildDefaultMap", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, new object[] { mapRoot });
            Invoke(map, "SetWorldActive", true);
            Camera camera = cameraRoot.AddComponent<Camera>();
            camera.aspect = aspect;
            camera.transform.position = new Vector3(0f, 1.1f, 3.2f);
            owner.transform.position = new Vector3(x, 0f, z);
            Component director = cameraRoot.AddComponent(WorldType("WorldCameraDirector"));
            Assert.That(Invoke(director, "EnterWorld", camera, null, owner.transform, null), Is.EqualTo(true));
            SetField(director, "worldMap", map);
            float started = Field<float>(director, "transitionStartedAt");
            for (int step = 0; step <= 12; step++)
            {
                InvokeNonPublic(director, "UpdateTransition", started + step * .11f);
                Assert.That(camera.transform.position.x, Is.InRange(-3.2001f, 3.2001f));
                Assert.That(camera.transform.position.z, Is.InRange(-3.2001f, 3.2001f));
                Assert.That(camera.transform.position.y, Is.InRange(.8499f, 1.3001f));
            }
            Assert.That(Property<object>(director, "Phase").ToString(), Is.EqualTo("Active"));
            Assert.That(camera.transform.position.y, Is.EqualTo(1.3f).Within(.001f));
            Vector3 separation = camera.transform.position - owner.transform.position;
            separation.y = 0f;
            Assert.That(separation.magnitude, Is.EqualTo(3.2f).Within(.001f),
                "The lens must orbit indoors instead of collapsing against an avatar at a wall.");
            for (int side = -1; side <= 1; side += 2)
            for (int depth = -1; depth <= 1; depth += 2)
            for (int height = 0; height <= 1; height++)
            {
                Vector3 viewport = camera.WorldToViewportPoint(owner.transform.position +
                    new Vector3(side * .35f, height * 1.8f, depth * .2f));
                Assert.That(viewport.z, Is.GreaterThan(camera.nearClipPlane));
                Assert.That(viewport.x, Is.InRange(.06f, .94f));
                Assert.That(viewport.y, Is.InRange(.06f, .94f));
            }
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraRoot);
            UnityEngine.Object.DestroyImmediate(owner);
            UnityEngine.Object.DestroyImmediate(mapRoot);
        }
    }

    [TestCase("head", 390f / 844f)]
    [TestCase("upper_body", 390f / 844f)]
    [TestCase("head", 16f / 9f)]
    public void PersonalSpaceEntryPreservesActualCloseupProjectionBeforeMovingIndoors(
        string mode, float aspect)
    {
        using var fixture = new FramedWorldFixture(aspect);
        Invoke(fixture.Framing, "SetFramingMode", mode);
        Camera camera = fixture.Camera;
        Vector3 startPosition = camera.transform.position;
        Quaternion startRotation = camera.transform.rotation;
        float startFieldOfView = camera.fieldOfView;
        Bounds meshBounds = fixture.Body.bounds;
        Rect startProjection = ProjectBounds(camera, meshBounds);
        Assert.That(startPosition.y, Is.GreaterThan(1.3f),
            "This must exercise an actual Home closeup above the indoor eye-height limit.");

        fixture.EnterWorld();

        Assert.That(Vector3.Distance(camera.transform.position, startPosition), Is.LessThan(.0001f));
        Assert.That(Quaternion.Angle(camera.transform.rotation, startRotation), Is.LessThan(.001f));
        Assert.That(camera.fieldOfView, Is.EqualTo(startFieldOfView).Within(.0001f));
        AssertProjectionNear(ProjectBounds(camera, meshBounds), startProjection, .0001f,
            "Entering must preserve the last Home image, including its projected body size.");

        float started = Field<float>(fixture.Director, "transitionStartedAt");
        InvokeNonPublic(fixture.Director, "UpdateTransition", started + .001f);
        AssertProjectionNear(ProjectBounds(camera, meshBounds), startProjection, .0001f,
            "The first interpolation step must not hard-clamp the actual Home origin.");
        InvokeNonPublic(fixture.Director, "UpdateTransition", started + 1.201f);
        Assert.That(Property<object>(fixture.Director, "Phase").ToString(), Is.EqualTo("Active"));
        Assert.That(camera.transform.position.x, Is.InRange(-3.2001f, 3.2001f));
        Assert.That(camera.transform.position.z, Is.InRange(-3.2001f, 3.2001f));
        Assert.That(camera.transform.position.y, Is.EqualTo(1.3f).Within(.001f),
            "The destination must still obey the personal-space camera bounds.");
        Assert.That(camera.fieldOfView, Is.EqualTo(51f).Within(.001f));
        Assert.That(fixture.Root.transform.localScale, Is.EqualTo(Vector3.one));
    }


    [Test]
    public void PersonalSpaceFollowRemainsInsideAfterOwnerMovesAlongEveryWall()
    {
        var mapRoot = new GameObject("IndoorFollowMap");
        var cameraRoot = new GameObject("IndoorFollowCamera");
        var owner = new GameObject("IndoorFollowOwner");
        try
        {
            object map = WorldType("PersistentWorldMapController")
                .GetMethod("BuildDefaultMap", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, new object[] { mapRoot });
            Invoke(map, "SetWorldActive", true);
            Camera camera = cameraRoot.AddComponent<Camera>();
            camera.aspect = 390f / 844f;
            Component director = cameraRoot.AddComponent(WorldType("WorldCameraDirector"));
            Assert.That(Invoke(director, "EnterWorld", camera, null, owner.transform, null), Is.EqualTo(true));
            SetField(director, "worldMap", map);
            InvokeNonPublic(director, "UpdateTransition", Time.realtimeSinceStartup + 2f);
            Vector3[] corners = { new(-3.5f, 0f, -3.5f), new(-3.5f, 0f, 3.5f),
                new(3.5f, 0f, 3.5f), new(3.5f, 0f, -3.5f), Vector3.zero };
            foreach (Vector3 corner in corners)
            {
                Vector3 start = owner.transform.position;
                for (int step = 1; step <= 35; step++)
                {
                    owner.transform.position = Vector3.Lerp(start, corner, step / 35f);
                    InvokeNonPublic(director, "UpdateTransition", Time.realtimeSinceStartup + 2f);
                    Assert.That(camera.transform.position.x, Is.InRange(-3.2001f, 3.2001f));
                    Assert.That(camera.transform.position.z, Is.InRange(-3.2001f, 3.2001f));
                    Assert.That(camera.transform.position.y, Is.EqualTo(1.3f).Within(.001f));
                    Vector3 subject = camera.WorldToViewportPoint(owner.transform.position + Vector3.up * .95f);
                    Assert.That(subject.x, Is.EqualTo(.5f).Within(.001f));
                    Assert.That(subject.y, Is.EqualTo(.5f).Within(.001f));
                    Assert.That(subject.z, Is.GreaterThan(3.19f));
                }
            }
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraRoot);
            UnityEngine.Object.DestroyImmediate(owner);
            UnityEngine.Object.DestroyImmediate(mapRoot);
        }
    }







    [Test]
    public void OwnerBirdseyePoseStaysLowAndTranslatesWithOwner()
    {
        Type directorType = WorldType("WorldCameraDirector");
        MethodInfo calculate = directorType.GetMethod(
            "CalculateOwnerBirdseyePose",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(calculate, Is.Not.Null);
        Vector3 firstOwner = new(0f, 0f, 0f);
        Vector3 secondOwner = new(9f, 0f, -6f);
        object first = calculate.Invoke(
            null,
            new object[] { firstOwner, 51f, 9f / 16f });
        object second = calculate.Invoke(
            null,
            new object[] { secondOwner, 51f, 9f / 16f });

        Vector3 firstOffset = Property<Vector3>(first, "Position") - firstOwner;
        Vector3 secondOffset = Property<Vector3>(second, "Position") - secondOwner;
        Assert.That(firstOffset.y, Is.InRange(5.5f, 8.5f));
        Assert.That(secondOffset.y, Is.InRange(5.5f, 8.5f));
        Assert.That(Vector3.Distance(firstOffset, secondOffset), Is.LessThan(0.001f));
    }

    [Test]
    public void OwnerReferenceProjectsIntoLowerCenterSafeArea()
    {
        var cameraObject = new GameObject("OwnerCompositionCamera");
        var owner = new GameObject("OwnerReference");
        try
        {
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.fieldOfView = 51f;
            camera.aspect = 9f / 16f;
            owner.transform.position = new Vector3(3f, 0f, -2f);
            Type directorType = WorldType("WorldCameraDirector");
            MethodInfo calculate = directorType.GetMethod(
                "CalculateOwnerBirdseyePose",
                BindingFlags.Public | BindingFlags.Static);
            Assert.That(calculate, Is.Not.Null);
            object pose = calculate.Invoke(
                null,
                new object[] { owner.transform.position, camera.fieldOfView, camera.aspect });
            camera.transform.SetPositionAndRotation(
                Property<Vector3>(pose, "Position"),
                Property<Quaternion>(pose, "Rotation"));

            Vector3 viewport = camera.WorldToViewportPoint(
                owner.transform.position + Vector3.up);

            Assert.That(viewport.x, Is.InRange(0.42f, 0.58f));
            Assert.That(viewport.y, Is.InRange(0.18f, 0.46f));
            Assert.That(viewport.z, Is.GreaterThan(0f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(owner);
        }
    }

    [Test]
    public void OwnerEntryRotationFacesTheFinalBirdseyeCamera()
    {
        Type directorType = WorldType("WorldCameraDirector");
        MethodInfo calculatePose = directorType.GetMethod(
            "CalculateOwnerBirdseyePose",
            BindingFlags.Public | BindingFlags.Static);
        MethodInfo calculateRotation = directorType.GetMethod(
            "CalculateOwnerEntryRotation",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(calculatePose, Is.Not.Null);
        Assert.That(calculateRotation, Is.Not.Null);

        Vector3 ownerPosition = new(3f, 0f, -2f);
        object pose = calculatePose.Invoke(
            null,
            new object[] { ownerPosition, 51f, 9f / 16f });
        Quaternion rotation = (Quaternion)calculateRotation.Invoke(
            null,
            new object[]
            {
                ownerPosition,
                9f / 16f,
                Quaternion.Euler(0f, 37f, 0f),
            });
        Vector3 directionToCamera =
            Property<Vector3>(pose, "Position") - ownerPosition;
        directionToCamera.y = 0f;

        Assert.That(
            Vector3.Dot(
                rotation * Vector3.forward,
                directionToCamera.normalized),
            Is.GreaterThan(0.999f));
    }

    [Test]
    public void OwnerLeaseBindAppliesTheFinalBirdseyeFacing()
    {
        var cameraObject = new GameObject("OwnerEntryCamera");
        var receiverObject = new GameObject("OwnerEntryReceiver");
        var avatarObject = new GameObject("OwnerEntryAvatar");
        var ownerObject = new GameObject("OwnerEntryLease");
        avatarObject.transform.SetParent(receiverObject.transform, false);

        try
        {
            cameraObject.tag = "MainCamera";
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.aspect = 9f / 16f;
            Type receiverType = Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
            Assert.That(receiverType, Is.Not.Null);
            Component receiver = receiverObject.AddComponent(receiverType);
            SetField(receiver, "avatarRoot", avatarObject.transform);
            SetField(receiver, "bundledAvatarRoot", avatarObject.transform);

            Component lease = ownerObject.AddComponent(
                WorldType("WorldOwnerAvatarLease"));
            Vector3 ownerPosition = new(3f, 0f, -2f);
            Assert.That(
                Invoke(
                    lease,
                    "Bind",
                    receiver,
                    null,
                    ownerPosition,
                    Quaternion.Euler(0f, 37f, 0f)),
                Is.EqualTo(true));

            Type directorType = WorldType("WorldCameraDirector");
            MethodInfo calculatePose = directorType.GetMethod(
                "CalculateOwnerBirdseyePose",
                BindingFlags.Public | BindingFlags.Static);
            object pose = calculatePose.Invoke(
                null,
                new object[] { ownerPosition, 51f, camera.aspect });
            Vector3 directionToCamera =
                Property<Vector3>(pose, "Position") - ownerPosition;
            directionToCamera.y = 0f;

            Assert.That(
                Vector3.Dot(
                    ownerObject.transform.forward,
                    directionToCamera.normalized),
                Is.GreaterThan(0.999f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(ownerObject);
            UnityEngine.Object.DestroyImmediate(receiverObject);
            UnityEngine.Object.DestroyImmediate(avatarObject);
            UnityEngine.Object.DestroyImmediate(cameraObject);
        }
    }

    [UnityTest]
    public IEnumerator ExitRestoresCapturedTransformAndFraming()
    {
        var cameraObject = new GameObject("WorldCameraFixture");
        var owner = new GameObject("OwnerTarget").transform;
        try
        {
            Camera camera = cameraObject.AddComponent<Camera>();
            Type framingType = Type.GetType(
                "Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp");
            Assert.That(framingType, Is.Not.Null);
            Component framing = cameraObject.AddComponent(framingType);
            // Other camera tests open Companion.unity. This fixture verifies
            // pose restoration without borrowing that scene's skinned avatar.
            SetField(framing, "autoFindTarget", false);
            framingType.GetProperty("TargetRoot")?.SetValue(framing, null);
            Type directorType = WorldType("WorldCameraDirector");
            Component director = cameraObject.AddComponent(directorType);
            camera.transform.SetPositionAndRotation(
                new Vector3(1.25f, 1.1f, 4.4f),
                Quaternion.Euler(3f, 178f, 0f));
            camera.fieldOfView = 37.5f;
            owner.position = new Vector3(4f, 0f, -3f);
            Vector3 savedPosition = camera.transform.position;
            Quaternion savedRotation = camera.transform.rotation;
            float savedFieldOfView = camera.fieldOfView;

            Assert.That(
                Invoke(
                director,
                "EnterWorld",
                camera,
                framing,
                owner,
                null),
                Is.EqualTo(true));
            yield return new WaitForSecondsRealtime(
                Constant<float>(directorType, "EnterDurationSeconds") + 0.1f);
            Assert.That(Property<object>(director, "Phase").ToString(), Is.EqualTo("Active"));
            Assert.That(camera.fieldOfView, Is.EqualTo(51f).Within(0.01f));
            Invoke(director, "BeginExit", (object)null);
            yield return new WaitForSecondsRealtime(
                Constant<float>(directorType, "ExitDurationSeconds") + 0.1f);

            Assert.That(Property<object>(director, "Phase").ToString(), Is.EqualTo("Home"));
            Assert.That(
                Vector3.Distance(camera.transform.position, savedPosition),
                Is.LessThan(0.01f));
            Assert.That(
                Quaternion.Angle(camera.transform.rotation, savedRotation),
                Is.LessThan(0.01f));
            Assert.That(camera.fieldOfView, Is.EqualTo(savedFieldOfView).Within(0.01f));
            Assert.That(((Behaviour)framing).enabled, Is.True);
            Assert.That(
                Property<string>(framing, "FramingMode"),
                Is.EqualTo("hero_full_body"));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(owner.gameObject);
        }
    }

    [Test]
    public void ExitRestoresAvatarBeforeHomeFramingRuns()
    {
        var cameraObject = new GameObject("WorldExitOrderingCamera");
        var avatarRoot = new GameObject("ActiveAvatar");
        GameObject body = GameObject.CreatePrimitive(PrimitiveType.Capsule);
        var owner = new GameObject("WorldOwner").transform;
        try
        {
            body.transform.SetParent(avatarRoot.transform, false);
            body.transform.localPosition = Vector3.up;
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.aspect = 9f / 16f;
            camera.fieldOfView = 37.5f;
            Type framingType = Type.GetType(
                "Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp");
            Assert.That(framingType, Is.Not.Null);
            Component framing = cameraObject.AddComponent(framingType);
            framingType.GetProperty("TargetRoot")?.SetValue(
                framing,
                avatarRoot.transform);
            framingType.GetMethod("FrameNow")?.Invoke(
                framing,
                Array.Empty<object>());

            Type directorType = WorldType("WorldCameraDirector");
            Component director = cameraObject.AddComponent(directorType);
            owner.position = new Vector3(8f, 0f, -5f);
            Assert.That(
                Invoke(director, "EnterWorld", camera, framing, owner, null),
                Is.EqualTo(true));

            avatarRoot.transform.position = owner.position;
            Invoke(
                director,
                "BeginExit",
                (Action)(() => avatarRoot.transform.position = Vector3.zero));
            SetField(
                director,
                "transitionStartedAt",
                Time.realtimeSinceStartup -
                Constant<float>(directorType, "ExitDurationSeconds") - 0.1f);
            InvokeNonPublic(
                director,
                "UpdateTransition",
                Time.realtimeSinceStartup);

            Assert.That(
                camera.transform.position.x,
                Is.EqualTo(0f).Within(0.05f),
                "The owner must be returned home before full-body framing samples its position.");
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(avatarRoot);
            UnityEngine.Object.DestroyImmediate(owner.gameObject);
        }
    }

    [Test]
    public void EnsureExitToHomeDoesNotRestartAnActiveExit()
    {
        var cameraObject = new GameObject("WorldExitIdempotencyCamera");
        var owner = new GameObject("WorldExitIdempotencyOwner").transform;
        try
        {
            Camera camera = cameraObject.AddComponent<Camera>();
            Type directorType = WorldType("WorldCameraDirector");
            Component director = cameraObject.AddComponent(directorType);
            Assert.That(
                Invoke(director, "EnterWorld", camera, null, owner, null),
                Is.EqualTo(true));
            int completionCount = 0;
            Invoke(director, "BeginExit", (Action)(() => completionCount++));
            float startedAt = Field<float>(director, "transitionStartedAt");

            Invoke(director, "EnsureExitToHome");

            Assert.That(Property<object>(director, "Phase").ToString(), Is.EqualTo("Leaving"));
            Assert.That(Field<float>(director, "transitionStartedAt"), Is.EqualTo(startedAt));
            SetField(
                director,
                "transitionStartedAt",
                Time.realtimeSinceStartup -
                Constant<float>(directorType, "ExitDurationSeconds") - 0.1f);
            InvokeNonPublic(director, "UpdateTransition", Time.realtimeSinceStartup);
            Assert.That(completionCount, Is.EqualTo(1));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(owner.gameObject);
        }
    }

    [Test]
    public void EnsureExitToHomeStartsExitOnlyOutsideHome()
    {
        var cameraObject = new GameObject("WorldExitFallbackCamera");
        var owner = new GameObject("WorldExitFallbackOwner").transform;
        try
        {
            Camera camera = cameraObject.AddComponent<Camera>();
            Type directorType = WorldType("WorldCameraDirector");
            Component director = cameraObject.AddComponent(directorType);

            Invoke(director, "EnsureExitToHome");
            Assert.That(Property<object>(director, "Phase").ToString(), Is.EqualTo("Home"));

            Assert.That(
                Invoke(director, "EnterWorld", camera, null, owner, null),
                Is.EqualTo(true));
            SetField(
                director,
                "phase",
                Enum.Parse(directorType.Assembly.GetType("Maaso.World.WorldCameraPhase"), "Active"));
            Invoke(director, "EnsureExitToHome");

            Assert.That(Property<object>(director, "Phase").ToString(), Is.EqualTo("Leaving"));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(cameraObject);
            UnityEngine.Object.DestroyImmediate(owner.gameObject);
        }
    }

    private sealed class FramedWorldFixture : IDisposable
    {
        public readonly GameObject Root;
        public readonly Renderer Body;
        public readonly Camera Camera;
        public readonly Component Framing;
        public readonly Component Director;
        public readonly Component Map;
        private readonly GameObject receiverRoot;
        private readonly GameObject ownerRoot;
        private readonly Component lease;
        private readonly Component receiver;
        public int HomeRestorationCount { get; private set; }

        public FramedWorldFixture(float aspect)
        {
            var mapRoot = new GameObject("Framed world map");
            Map = (Component)WorldType("PersistentWorldMapController")
                .GetMethod("BuildDefaultMap").Invoke(null, new object[] { mapRoot });
            // BuildDefaultMap supplies anchors and the ground collider only;
            // its PersistentEnvironmentRoot is deliberately empty until the
            // actual room is installed. Supply visible room geometry so this
            // fixture exercises Home room framing, not its no-room fallback.
            GameObject wall = GameObject.CreatePrimitive(PrimitiveType.Cube);
            wall.name = "Home room wall";
            wall.transform.SetParent(Property<Transform>(Map, "PersistentEnvironmentRoot"), false);
            wall.transform.localPosition = new Vector3(3.9f, 1.2f, 0f);
            wall.transform.localScale = new Vector3(.2f, 2.4f, 8f);
            receiverRoot = new GameObject("Framed world receiver");
            Root = new GameObject("Framed world avatar");
            Root.transform.SetParent(receiverRoot.transform, false);
            GameObject body = GameObject.CreatePrimitive(PrimitiveType.Cube);
            body.name = "Body";
            body.transform.SetParent(Root.transform, false);
            body.transform.localPosition = new Vector3(0f, .9f, 0f);
            body.transform.localScale = new Vector3(.65f, 1.8f, .25f);
            Body = body.GetComponent<Renderer>();
            Camera = new GameObject("Framed world camera") { tag = "MainCamera" }.AddComponent<Camera>();
            Camera.aspect = aspect;
            Camera.fieldOfView = 35f;
            Camera.clearFlags = CameraClearFlags.SolidColor;
            Camera.backgroundColor = Color.gray;
            Type framingType = Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp", true);
            Framing = Camera.gameObject.AddComponent(framingType);
            SetField(Framing, "autoFindTarget", false);
            framingType.GetProperty("TargetRoot").SetValue(Framing, Root.transform);
            receiver = receiverRoot.AddComponent(Type.GetType(
                "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true));
            SetField(receiver, "avatarRoot", Root.transform);
            SetField(receiver, "bundledAvatarRoot", Root.transform);
            // This is an owned, visible Home avatar. Without Flutter's grant,
            // returning the lease correctly reapplies the default hidden mask
            // and subsequent visible-geometry grounding is deliberately denied.
            Invoke(receiver, "OnFlutterCommand",
                "{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}");
            SetField(Map, "avatarReceiver", receiver);
            Invoke(Map, "SetWorldActive", false);
            Assert.That(Property<Transform>(Framing, "TargetRoot"), Is.SameAs(Root.transform));
            AssertVisibleAndGrounded("initial Home");
            Director = Camera.gameObject.AddComponent(WorldType("WorldCameraDirector"));
            ownerRoot = new GameObject("Framed world owner lease");
            lease = ownerRoot.AddComponent(WorldType("WorldOwnerAvatarLease"));
        }

        public void EnterWorld()
        {
            Invoke(Map, "SetWorldActive", true);
            Assert.That(Invoke(Director, "EnterWorld", Camera, Framing, Root.transform, null), Is.True);
        }

        public void EnterWithLease(bool moveOwner)
        {
            Invoke(Map, "SetWorldActive", true);
            Transform homeAnchor = Property<Transform>(Map, "HomeAgentAnchor");
            Vector3 entryPosition = moveOwner ? new Vector3(2f, 0f, -2f) : Root.transform.position;
            Assert.That(Invoke(lease, "Bind", receiver, homeAnchor, entryPosition, Quaternion.identity), Is.True);
            Assert.That(Invoke(Director, "EnterWorld", Camera, Framing, ownerRoot.transform, null), Is.True);
        }

        public void BeginExitWithLease()
        {
            Invoke(lease, "BeginReturnToHome", 1f);
            Invoke(Director, "BeginExit", (Action)(() =>
            {
                Invoke(lease, "CompleteReturnToHome");
                AssertVisibleAndGrounded("completed lease");
                Invoke(Map, "SetWorldActive", false);
                AssertVisibleAndGrounded("restored Home map");
                HomeRestorationCount++;
            }));
            object[] homeQuery = { Property<Transform>(Map, "HomeAgentAnchor"), null, 0f };
            Assert.That(Invoke(Framing, "TryGetHomeReturnFramingPose", homeQuery), Is.True,
                "The fixture must exercise a validated Home destination, not the no-evidence fallback.");
            Assert.That(Vector3.Distance(Field<Vector3>(Director, "homePosition"),
                    Property<Vector3>(homeQuery[1], "Position")), Is.LessThan(.0001f),
                "The director must adopt the validated Home shot before starting the return.");
            Assert.That(Field<float>(Director, "homeFieldOfView"),
                Is.EqualTo((float)homeQuery[2]).Within(.0001f));
        }

        private void AssertVisibleAndGrounded(string stage)
        {
            Assert.That(Body.enabled, Is.True, $"The local owner must remain visible at {stage}.");
            Assert.That(Body.forceRenderingOff, Is.False);
            float contactY = Constant<float>(WorldType("PersistentWorldMapController"), "GroundY") -
                Constant<float>(WorldType("WorldAvatarGrounding"), "GroundContactInset");
            Assert.That(Body.bounds.min.y, Is.EqualTo(contactY).Within(.00001f),
                $"The same physical ground contact must be maintained at {stage}.");
        }

        public void AdvanceLeaseReturn(float elapsed)
        {
            SetField(lease, "returnStartedAt", Time.realtimeSinceStartup - elapsed);
            InvokeNonPublic(lease, "UpdateReturnToHome");
        }

        public void Dispose()
        {
            UnityEngine.Object.DestroyImmediate(Camera.gameObject);
            UnityEngine.Object.DestroyImmediate(ownerRoot);
            UnityEngine.Object.DestroyImmediate(receiverRoot);
            UnityEngine.Object.DestroyImmediate(Map.gameObject);
        }
    }

    private static Rect ProjectBounds(Camera camera, Bounds bounds)
    {
        Vector2 minimum = new(float.PositiveInfinity, float.PositiveInfinity);
        Vector2 maximum = new(float.NegativeInfinity, float.NegativeInfinity);
        for (int x = -1; x <= 1; x += 2)
        for (int y = -1; y <= 1; y += 2)
        for (int z = -1; z <= 1; z += 2)
        {
            Vector3 corner = bounds.center + Vector3.Scale(bounds.extents, new Vector3(x, y, z));
            Vector3 point = camera.WorldToViewportPoint(corner);
            Assert.That(point.z, Is.GreaterThan(camera.nearClipPlane));
            minimum = Vector2.Min(minimum, point);
            maximum = Vector2.Max(maximum, point);
        }
        return Rect.MinMaxRect(minimum.x, minimum.y, maximum.x, maximum.y);
    }

    private static void AssertProjectionNear(Rect actual, Rect expected, float tolerance, string message)
    {
        Assert.That(Vector2.Distance(actual.center, expected.center), Is.LessThan(tolerance), message);
        Assert.That(Mathf.Abs(actual.width - expected.width), Is.LessThan(tolerance), message);
        Assert.That(Mathf.Abs(actual.height - expected.height), Is.LessThan(tolerance), message);
    }

    private static Type WorldType(string name)
    {
        Type type = Type.GetType($"Maaso.World.{name}, Assembly-CSharp");
        Assert.That(type, Is.Not.Null, name);
        return type;
    }

    private static object Invoke(object target, string method, params object[] arguments)
    {
        MethodInfo member = target.GetType().GetMethod(
            method,
            BindingFlags.Public | BindingFlags.Instance);
        Assert.That(member, Is.Not.Null, method);
        return member.Invoke(target, arguments);
    }

    private static object InvokeNonPublic(
        object target,
        string method,
        params object[] arguments)
    {
        MethodInfo member = target.GetType().GetMethod(
            method,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(member, Is.Not.Null, method);
        return member.Invoke(target, arguments);
    }

    private static void SetField(object target, string name, object value)
    {
        FieldInfo field = target.GetType().GetField(
            name,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, name);
        field.SetValue(target, value);
    }

    private static T Field<T>(object target, string name)
    {
        FieldInfo field = target.GetType().GetField(
            name,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(field, Is.Not.Null, name);
        return (T)field.GetValue(target);
    }

    private static T Property<T>(object target, string name)
    {
        PropertyInfo property = target.GetType().GetProperty(
            name,
            BindingFlags.Public | BindingFlags.Instance);
        Assert.That(property, Is.Not.Null, name);
        return (T)property.GetValue(target);
    }

    private static T Constant<T>(Type type, string name)
    {
        FieldInfo field = type.GetField(name, BindingFlags.Public | BindingFlags.Static);
        Assert.That(field, Is.Not.Null, name);
        return (T)field.GetRawConstantValue();
    }
}
