using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

public sealed class WorldCameraOcclusionTests
{
    [Test]
    public void EnteringWorldInstallsTheEffectAndItsShaderIsBundled()
    {
        using var fixture = new Fixture();
        Shader shader = Resources.Load<Shader>("MaasoWorldOcclusion");
        Assert.That(shader, Is.Not.Null,
            "The fade shader must be a local player dependency, including on iOS.");
        Assert.That(fixture.Effect, Is.Not.Null);
        Assert.That(Property<Transform>(fixture.Director, "OcclusionTarget"),
            Is.SameAs(fixture.Owner.transform));
        Invoke(fixture.Director, "BeginExit", (object)null);
        SetField(fixture.Director, "transitionStartedAt", Time.realtimeSinceStartup - 2f);
        InvokePrivate(fixture.Director, "UpdateTransition", Time.realtimeSinceStartup);
        Assert.That(Property<Transform>(fixture.Director, "OcclusionTarget"), Is.Null);
    }

    [Test]
    public void SightLineUsesTheRotatedAndScaledMeshRatherThanItsWorldBoundingBox()
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", new Vector3(3f, 2f, 4f));
        wall.transform.rotation = Quaternion.Euler(12f, 42f, 8f);
        wall.transform.localScale = new Vector3(5f, 2.5f, 0.1f);
        Vector3 origin = wall.transform.TransformPoint(new Vector3(0f, 0f, -4f));
        Vector3 target = wall.transform.TransformPoint(new Vector3(0f, 0f, 4f));
        Assert.That(Intersects(wall, origin, target), Is.True);
        Vector3 clearOrigin = wall.transform.TransformPoint(new Vector3(0.7f, 0f, -4f));
        Vector3 clearTarget = wall.transform.TransformPoint(new Vector3(0.7f, 0f, 4f));
        Assert.That(Intersects(wall, clearOrigin, clearTarget), Is.False,
            "A ray outside the actual local box must not fade a rotated wall.");
    }

    [Test]
    public void SightLineIsAFiniteSegmentAndHandlesACameraInsideTheWall()
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", Vector3.zero);
        wall.transform.localScale = Vector3.one * 2f;
        Assert.That(Intersects(wall, Vector3.zero, Vector3.forward * 4f), Is.True);
        Assert.That(Intersects(wall, Vector3.back * 5f, Vector3.back * 3f), Is.False,
            "Geometry beyond the person is not an occluder.");
        Assert.That(Intersects(wall, Vector3.forward * 5f, Vector3.forward * 3f), Is.False,
            "Geometry behind the camera is not an occluder.");
    }

    [TestCase(1)]
    [TestCase(2)]
    public void AuthoredRoomCeilingFadesWithoutAddingPhysicsColliders(int materialSlots)
    {
        using var fixture = new Fixture();
        GameObject prefab = Resources.Load<GameObject>("PersonalSpaceModel");
        Assert.That(prefab, Is.Not.Null);
        GameObject room = UnityEngine.Object.Instantiate(prefab, fixture.Visuals, false);
        foreach (Transform child in room.GetComponentsInChildren<Transform>(true))
            child.gameObject.layer = 30;
        Renderer roof = room.GetComponentsInChildren<Renderer>(true)
            .SingleOrDefault(value => value.name == "V2_Ceiling");
        Assert.That(roof, Is.Not.Null, "The authored V2 ceiling must be present in the room prefab.");
        if (materialSlots == 2)
        {
            Renderer wall = room.GetComponentsInChildren<Renderer>(true)
                .FirstOrDefault(value => value.name == "V2_East_Wall");
            Assert.That(wall, Is.Not.Null, "The second material must come from the authored east wall.");
            Assert.That(wall.sharedMaterial, Is.Not.SameAs(roof.sharedMaterial));
            roof.sharedMaterials = new[] { roof.sharedMaterial, wall.sharedMaterial };
        }
        Material[] original = roof.sharedMaterials;
        Assert.That(roof.GetComponentsInChildren<Collider>(true), Is.Empty,
            "Only the tested roof may be collider-free; V4WalkableFloor remains collidable.");
        fixture.Camera.transform.SetPositionAndRotation(new Vector3(0f, 6.2f, -7.2f),
            Quaternion.LookRotation(new Vector3(0f, 1f, 0f) - new Vector3(0f, 6.2f, -7.2f)));
        fixture.Frame(10f, 0.3f);
        Assert.That(Opacity(roof), Is.Zero.Within(0.005f));
        Assert.That(roof.sharedMaterials, Has.Length.EqualTo(materialSlots));
        foreach (Material material in roof.sharedMaterials)
            Assert.That(material.GetFloat("_OcclusionOpacity"), Is.Zero.Within(0.005f),
                "The overhead room view should remove the roof instead of covering it with visible dither.");
        fixture.RestoreFrame();
        CollectionAssert.AreEqual(original, roof.sharedMaterials);
        Assert.That(roof.GetComponentsInChildren<Collider>(true), Is.Empty,
            "Camera visibility must not add a roof collider or change walking physics.");
    }

    [TestCase("PS_Ceiling")]
    [TestCase("V2_Ceiling")]
    public void OverheadCutawayRemovesRoofBeyondOwnerSightLineAndRestoresItForHome(string name)
    {
        using var fixture = new Fixture();
        Renderer roof = fixture.Wall(name, new Vector3(0f, 3.8f, 3.0f));
        roof.transform.localScale = new Vector3(10f, 0.1f, 3f);
        Material original = roof.sharedMaterial;
        Vector3 eye = new Vector3(0f, 6.2f, -7.2f);
        fixture.Camera.transform.SetPositionAndRotation(eye,
            Quaternion.LookRotation(fixture.Body.bounds.center - eye));
        Assert.That(Intersects(roof, eye, fixture.Body.bounds.center), Is.False,
            "This roof covers the far room, not the owner.");
        fixture.Frame(10f, 0.3f);
        Assert.That(roof.sharedMaterial.GetFloat("_OcclusionOpacity"), Is.Zero.Within(0.005f));
        fixture.RestoreFrame();
        Assert.That(roof.sharedMaterial, Is.SameAs(original),
            "Home and other cameras must retain the original roof.");
        ((Behaviour)fixture.Effect).enabled = false;
        Assert.That(roof.sharedMaterial, Is.SameAs(original));
    }

    [TestCase("PS_Wall_Back")]
    [TestCase("PS_FloorLamp_Shade")]
    [TestCase("PS_Armchair_Back")]
    [TestCase("V2_West_Wall")]
    [TestCase("V2_East_Wall")]
    [TestCase("V2_South_Wall_East")]
    [TestCase("V2_South_Door_Lintel")]
    [TestCase("V2_Entrance_Baked")]
    [TestCase("V2_Lounge_Baked")]
    [TestCase("V2_CoffeeTable_Baked")]
    [TestCase("V2_WorkDesk_Baked")]
    [TestCase("V2_WorkChair_Baked")]
    [TestCase("V2_Bookshelf")]
    [TestCase("V2_Sideboard_Baked")]
    [TestCase("V2_Strelitzia_Baked")]
    [TestCase("V2_Window_Vertical_Profile.001")]
    public void NewRoomGeometryOnTheSightLineRevealsTheOwnerAndRestores(string name)
    {
        using var fixture = new Fixture();
        Renderer surface = fixture.Wall(name, new Vector3(0f, 1f, -2.5f));
        Material original = surface.sharedMaterial;
        fixture.Frame(10f, 0.3f);
        AssertFaded(surface);
        fixture.RestoreFrame();
        Assert.That(surface.sharedMaterial, Is.SameAs(original));
    }

    [Test]
    public void BakedEmissionAndDisabledReflectionsSurviveTheTemporaryFade()
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("V2_West_Wall", new Vector3(0f, 1f, -2.5f));
        Material original = wall.sharedMaterial;
        original.color = Color.black;
        original.SetTexture("_EmissionMap", Texture2D.whiteTexture);
        original.SetColor("_EmissionColor", new Color(0.72f, 0.64f, 0.53f, 1f));
        original.SetFloat("_Metallic", 0f);
        original.SetFloat("_Glossiness", 0f);
        foreach (string keyword in new[] { "_EMISSION", "_SPECULARHIGHLIGHTS_OFF", "_GLOSSYREFLECTIONS_OFF" })
            original.EnableKeyword(keyword);

        fixture.Frame(10f, 0.3f);
        AssertFaded(wall);
        Material faded = wall.sharedMaterial;
        Assert.That(faded.color, Is.EqualTo(Color.black));
        Assert.That(faded.GetTexture("_EmissionMap"), Is.SameAs(original.GetTexture("_EmissionMap")));
        Color actualEmission = faded.GetColor("_EmissionColor");
        Color expectedEmission = original.GetColor("_EmissionColor");
        for (int channel = 0; channel < 4; channel++)
            Assert.That(actualEmission[channel], Is.EqualTo(expectedEmission[channel]).Within(.000001f),
                "Fade material must retain the source emission multiplier.");
        foreach (string keyword in new[] { "_EMISSION", "_SPECULARHIGHLIGHTS_OFF", "_GLOSSYREFLECTIONS_OFF" })
            Assert.That(faded.IsKeywordEnabled(keyword), Is.True, keyword);
        fixture.RestoreFrame();
        Assert.That(wall.sharedMaterial, Is.SameAs(original));
    }

    [TestCase("Standard", 3)]
    [TestCase("Unlit/Color", -1)]
    public void NonOpaqueOrCustomMaterialsKeepTheirOriginalShader(string shaderName, int mode)
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        Material opaque = wall.sharedMaterial;
        Shader shader = Shader.Find(shaderName);
        Assert.That(shader, Is.Not.Null, shaderName);
        var custom = new Material(shader) { color = new Color(0.2f, 0.5f, 0.8f, 0.35f) };
        if (mode >= 0) custom.SetFloat("_Mode", mode);
        try
        {
            wall.sharedMaterial = custom;
            fixture.Frame(10f, 0.3f);
            Assert.That(wall.sharedMaterial, Is.SameAs(custom),
                "A streamed object sharing a room mesh name must keep its own material behavior.");
            Assert.That(custom.shader, Is.SameAs(shader));
            Assert.That(custom.color.a, Is.EqualTo(0.35f).Within(0.001f));

            wall.sharedMaterial = opaque;
            fixture.Frame(11f, 0.3f);
            AssertFaded(wall);
            wall.sharedMaterial = custom;
            fixture.Frame(11.1f, 0.1f);
            Assert.That(wall.sharedMaterial, Is.SameAs(custom),
                "A material changed during a fade must immediately leave the fade path.");
            fixture.RestoreFrame();
            Assert.That(wall.sharedMaterial, Is.SameAs(custom));
        }
        finally
        {
            fixture.RestoreFrame();
            wall.sharedMaterial = opaque;
            UnityEngine.Object.DestroyImmediate(custom);
        }
    }

    [TestCase("V2_Distant_Ocean")]
    [TestCase("V2_Linen_Drape_West")]
    [TestCase("V2_Linen_Drape_East")]
    public void AuthoredWindowSceneryFadesAlongTheMovingCameraSightLineAndRecovers(string subjectName)
    {
        using var fixture = new Fixture();
        GameObject room = fixture.Room();
        Renderer[] renderers = room.GetComponentsInChildren<Renderer>(true);
        var original = renderers.ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
        Renderer[] windowScenery = renderers.Where(renderer =>
            renderer.name == "V2_Distant_Ocean" ||
            renderer.name.StartsWith("V2_Linen_Drape_", StringComparison.Ordinal)).ToArray();
        CollectionAssert.AreEquivalent(new[]
            { "V2_Distant_Ocean", "V2_Linen_Drape_West", "V2_Linen_Drape_East" },
            windowScenery.Select(renderer => renderer.name),
            "The shipped vista and curtains must replace every retired block building.");
        Assert.That(renderers.Any(renderer => renderer.name.StartsWith("PS_Bed_", StringComparison.Ordinal) ||
            renderer.name.StartsWith("V2_Bed", StringComparison.Ordinal)), Is.False,
            "The coastal room is a living area and workspace without a bed.");

        fixture.MoveOwnerAndCamera(0f, 0f);
        fixture.Frame(10f, 0.3f);
        foreach (Renderer renderer in windowScenery)
            CollectionAssert.AreEqual(original[renderer], renderer.sharedMaterials,
                renderer.name + " must remain intact when it is not between the camera and the person.");
        fixture.RestoreFrame();
        AssertMaterialsRestored(original);

        Renderer subject = renderers.Single(renderer => renderer.name == subjectName);
        Renderer frame = renderers.Single(renderer => renderer.name == "V2_Window_Stone_Sill");
        float x = subject.bounds.center.x;
        float z = Mathf.Max(subject.bounds.max.z, frame.bounds.max.z) + 0.35f;
        fixture.MoveOwnerAndCamera(x, z);
        fixture.Frame(11f, 0.3f);
        foreach (Renderer renderer in windowScenery)
            CollectionAssert.AreEqual(original[renderer], renderer.sharedMaterials,
                "The normal +Z camera must preserve the vista and curtains behind the person.");
        fixture.RestoreFrame();
        AssertMaterialsRestored(original);

        // Also exercise an explicit window-side observer. This is deliberately
        // the opposite direction from the current personal-space camera: the
        // same scenery must fade only when it moves in front of the person.
        Vector3 eye = new Vector3(x, fixture.Body.bounds.center.y,
            Mathf.Min(subject.bounds.min.z, fixture.Owner.transform.position.z) - 7.2f);
        fixture.Camera.farClipPlane = 200f;
        fixture.Camera.transform.SetPositionAndRotation(eye,
            Quaternion.LookRotation(fixture.Body.bounds.center - eye));
        Assert.That(Intersects(subject, fixture.Camera.transform.position, fixture.Body.bounds.center), Is.True,
            subjectName + " must actually lie on the selected camera-to-person sight line.");
        fixture.Frame(12f, 0.4f);
        AssertFaded(subject);
        fixture.RestoreFrame();
        AssertMaterialsRestored(original);

        fixture.MoveOwnerAndCamera(0f, 0f);
        fixture.Frame(13f, 0.4f);
        foreach (Renderer renderer in windowScenery)
            CollectionAssert.AreEqual(original[renderer], renderer.sharedMaterials,
                renderer.name + " must recover when the person walks away from the window.");
        fixture.RestoreFrame();
        AssertMaterialsRestored(original);
        Assert.That(subject.GetComponentsInChildren<Collider>(true), Is.Empty,
            "Fading the tested window scenery must not add a collider.");
    }

    [TestCase("V2_Distant_Ocean")]
    [TestCase("V2_Linen_Drape_West")]
    [TestCase("V2_Linen_Drape_East")]
    public void RenderedPersonRemainsVisibleThroughTheActualWindowBackdropAndCurtains(string subjectName)
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
            Assert.Ignore("Pixel verification needs Unity to run without -nographics.");
        using var fixture = new Fixture();
        GameObject room = fixture.Room();
        var original = room.GetComponentsInChildren<Renderer>(true)
            .ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
        Renderer subject = original.Keys.Single(renderer => renderer.name == subjectName);
        Renderer frame = original.Keys.Single(renderer => renderer.name == "V2_Window_Stone_Sill");
        float x = subject.bounds.center.x;
        float z = Mathf.Max(subject.bounds.max.z, frame.bounds.max.z) + 0.35f;
        fixture.MoveOwnerAndCamera(x, z);
        fixture.Body.sharedMaterial.color = Color.magenta;
        fixture.Body.sharedMaterial.SetColor("_EmissionColor", Color.magenta);
        fixture.Body.sharedMaterial.EnableKeyword("_EMISSION");
        Texture2D reference = null;
        Texture2D blocked = null;
        Texture2D revealed = null;
        try
        {
            ((Behaviour)fixture.Effect).enabled = false;
            room.SetActive(false);
            reference = Capture(fixture.Camera, 256, 456);
            room.SetActive(true);
            blocked = Capture(fixture.Camera, 256, 456);
            ((Behaviour)fixture.Effect).enabled = true;
            fixture.Frame(Time.realtimeSinceStartup, 0.3f);
            fixture.RestoreFrame();
            revealed = Capture(fixture.Camera, 256, 456);

            Color32[] referencePixels = reference.GetPixels32();
            Color32[] revealedPixels = revealed.GetPixels32();
            int referenceCount = 0;
            int visibleCount = 0;
            int minimumBodyRow = reference.height;
            int maximumBodyRow = -1;
            for (int index = 0; index < referencePixels.Length; index++)
            {
                if (!IsMagenta(referencePixels[index])) continue;
                referenceCount++;
                int row = index / reference.width;
                minimumBodyRow = Math.Min(minimumBodyRow, row);
                maximumBodyRow = Math.Max(maximumBodyRow, row);
                if (IsMagenta(revealedPixels[index])) visibleCount++;
            }
            string position = subjectName;
            foreach (var capture in new[] { (Name: "reference", Image: reference),
                         (Name: "blocked", Image: blocked), (Name: "revealed", Image: revealed) })
                System.IO.File.WriteAllBytes(System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                    $"maaso-window-occlusion-{position}-{capture.Name}.png"), capture.Image.EncodeToPNG());
            Assert.That(referenceCount, Is.GreaterThan(250),
                "The reference must contain a substantial visible person, not an empty camera frame.");
            Assert.That(visibleCount, Is.GreaterThanOrEqualTo(referenceCount * 0.75f),
                $"At x={x}, z={z} only {visibleCount}/{referenceCount} person pixels remain visible. " +
                "Room furniture or window geometry is still hiding the person despite the fade being enabled.");
            if (subjectName.StartsWith("V2_Linen_Drape_", StringComparison.Ordinal))
            {
                // A visible torso can conceal a lost leg in the whole-body score.
                // ReadPixels rows begin at the bottom of the reference image.
                int lowerBodyEndRow = minimumBodyRow +
                    Mathf.FloorToInt((maximumBodyRow - minimumBodyRow) * 0.35f);
                int lowerBodyReference = 0;
                int lowerBodyVisible = 0;
                for (int index = 0; index < referencePixels.Length; index++)
                {
                    if (index / reference.width > lowerBodyEndRow ||
                        !IsMagenta(referencePixels[index])) continue;
                    lowerBodyReference++;
                    if (IsMagenta(revealedPixels[index])) lowerBodyVisible++;
                }
                Assert.That(lowerBodyReference, Is.GreaterThan(100));
                Assert.That(lowerBodyVisible, Is.GreaterThanOrEqualTo(lowerBodyReference * 0.75f),
                    $"The window sill or curtain still hides the legs: {lowerBodyVisible}/{lowerBodyReference} " +
                    "pixels remain in the lower 35% of the unobstructed person.");
            }
            AssertMaterialsRestored(original);
        }
        finally
        {
            if (reference != null) UnityEngine.Object.DestroyImmediate(reference);
            if (blocked != null) UnityEngine.Object.DestroyImmediate(blocked);
            if (revealed != null) UnityEngine.Object.DestroyImmediate(revealed);
        }
    }

    [Test]
    public void RealHumanoidFeetRevealTheSofaDespiteItsConservativeSkinBounds()
    {
        using var fixture = new Fixture();
        GameObject room = fixture.Room();
        Renderer[] roomRenderers = room.GetComponentsInChildren<Renderer>(true);
        var originals = roomRenderers.ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
        Renderer platform = roomRenderers.Single(renderer => renderer.name == "V4_Sofa_Baked");
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
            "Assets/MaasoAvatar/Models/Default/Joy.vrm");
        RuntimeAnimatorController controller = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
            "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
        Assert.That(prefab, Is.Not.Null);
        Assert.That(controller, Is.Not.Null);
        fixture.Body.gameObject.SetActive(false);
        GameObject avatar = UnityEngine.Object.Instantiate(prefab, fixture.Owner.transform, false);
        foreach (Transform child in avatar.GetComponentsInChildren<Transform>(true))
            child.gameObject.layer = 30;
        Animator animator = avatar.GetComponentInChildren<Animator>(true);
        Assert.That(animator, Is.Not.Null);
        Assert.That(animator.avatar, Is.Not.Null);
        Assert.That(animator.avatar.isValid && animator.avatar.isHuman, Is.True);
        animator.runtimeAnimatorController = controller;
        animator.applyRootMotion = false;
        animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
        animator.Rebind();
        int idle = Animator.StringToHash("idle_shrug");
        Assert.That(animator.HasState(0, idle), Is.True);
        for (int layer = 0; layer < animator.layerCount; layer++)
            if (animator.HasState(layer, idle)) animator.Play(idle, layer, 0.5f);
        animator.Update(1f / 60f);
        Assert.That(Invoke(fixture.Map, "AlignHomeAvatar", avatar.transform), Is.EqualTo(true));
        // The official camera is on +Z. Stand beyond the sofa's -Z edge so
        // the sofa lies between the camera and the real humanoid feet.
        float bedX = platform.bounds.center.x;
        float bedZ = platform.bounds.min.z - 0.35f;
        fixture.MoveOwnerAndCamera(bedX, bedZ);
        fixture.Owner.transform.rotation = (Quaternion)WorldType("WorldCameraDirector")
            .GetMethod("CalculateOwnerEntryRotation", BindingFlags.Public | BindingFlags.Static)
            .Invoke(null, new object[] { fixture.Owner.transform.position, fixture.Camera.aspect, Quaternion.identity });

        SkinnedMeshRenderer[] skins = avatar.GetComponentsInChildren<SkinnedMeshRenderer>(true);
        Assert.That(skins, Is.Not.Empty);
        Transform leftFoot = animator.GetBoneTransform(HumanBodyBones.LeftFoot);
        Transform rightFoot = animator.GetBoneTransform(HumanBodyBones.RightFoot);
        Assert.That(leftFoot, Is.Not.Null);
        Assert.That(rightFoot, Is.Not.Null);
        Vector3 leftBefore = leftFoot.position;
        Vector3 rightBefore = rightFoot.position;
        // This regression requires generous animation bounds, not a particular
        // model's importer margin. Joy legitimately has tighter bounds than the
        // previous avatar. Construct the conservative margin explicitly while
        // keeping its real mesh, Humanoid pose and occluded feet unchanged.
        foreach (SkinnedMeshRenderer skin in skins)
        {
            Vector3 marginPoint = skin.bounds.center;
            marginPoint.z = platform.bounds.min.z + 0.10f;
            Bounds conservativeBounds = skin.localBounds;
            conservativeBounds.Encapsulate(skin.transform.InverseTransformPoint(marginPoint));
            skin.localBounds = conservativeBounds;
        }
        Bounds skinBounds = skins[0].bounds;
        foreach (SkinnedMeshRenderer skin in skins.Skip(1)) skinBounds.Encapsulate(skin.bounds);
        Assert.That(skinBounds.max.z, Is.GreaterThan(platform.bounds.min.z + 0.02f),
            "The fixture's conservative real-skin bounds must overlap the sofa's far edge; a small proxy would miss this regression.");
        Ray footRay = fixture.Camera.ViewportPointToRay(fixture.Camera.WorldToViewportPoint(leftFoot.position));
        Assert.That(Intersects(platform, footRay.origin, leftFoot.position), Is.True,
            "This actual humanoid foot must lie behind the sofa even though its conservative skin bounds overlap it.");
        fixture.Frame(10f, 0.3f);
        AssertFaded(platform);
        Assert.That(Vector3.Distance(leftFoot.position, leftBefore), Is.LessThan(0.000001f));
        Assert.That(Vector3.Distance(rightFoot.position, rightBefore), Is.LessThan(0.000001f),
            "Visibility detection must only read the existing pose, never move the feet or change the animation.");
        fixture.RestoreFrame();
        AssertMaterialsRestored(originals);

        fixture.MoveOwnerAndCamera(0f, 0f);
        fixture.Frame(11f, 0.4f);
        CollectionAssert.AreEqual(originals[platform], platform.sharedMaterials);
        fixture.RestoreFrame();
        AssertMaterialsRestored(originals);

        fixture.MoveOwnerAndCamera(bedX, bedZ);
        fixture.Frame(12f, 0.3f);
        AssertFaded(platform);
        ((Behaviour)fixture.Effect).enabled = false;
        AssertMaterialsRestored(originals);
    }

    [Test]
    public void FadePreservesSourceMaterialsAndPropertyBlocksAndRestoresAfterRendering()
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        Material original = wall.sharedMaterial;
        Color originalColor = original.color;
        var block = new MaterialPropertyBlock();
        int sentinel = Shader.PropertyToID("_OcclusionTestSentinel");
        block.SetFloat(sentinel, 0.37f);
        wall.SetPropertyBlock(block);
        fixture.Frame(10f, 0.04f);
        float earlyOpacity = Opacity(wall);
        Assert.That(earlyOpacity, Is.GreaterThan(0.08f).And.LessThan(1f));
        fixture.RestoreFrame();
        Assert.That(wall.sharedMaterial, Is.SameAs(original));
        fixture.Frame(10.3f, 0.3f);
        Assert.That(Opacity(wall), Is.EqualTo(0.08f).Within(0.005f));
        Assert.That(original.color, Is.EqualTo(originalColor));
        var restoredBlock = new MaterialPropertyBlock();
        wall.GetPropertyBlock(restoredBlock);
        Assert.That(restoredBlock.GetFloat(sentinel), Is.EqualTo(0.37f));
        fixture.RestoreFrame();
        Assert.That(wall.sharedMaterial, Is.SameAs(original),
            "A different camera must see the original material after this render.");
    }

    [Test]
    public void OnlyWallsBetweenTheCameraAndThePersonFade()
    {
        using var fixture = new Fixture();
        Renderer blocking = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        Renderer behind = fixture.Wall("PS_Wall_Right", new Vector3(0f, 1f, 3f));
        Renderer outside = fixture.Wall("PS_Window_Wall_Header", new Vector3(10f, 1f, -2.5f));
        Material behindMaterial = behind.sharedMaterial;
        Material outsideMaterial = outside.sharedMaterial;
        fixture.Frame(10f, 0.3f);
        AssertFaded(blocking);
        Assert.That(behind.sharedMaterial, Is.SameAs(behindMaterial));
        Assert.That(outside.sharedMaterial, Is.SameAs(outsideMaterial));
    }

    [TestCase("PS_Plant_Olive_Leaves")]
    [TestCase("PS_Plant_Olive_Stems")]
    [TestCase("PS_Plant_Olive_Pot")]
    public void OlivePartsFadeOnlyOnTheSightLineWithoutCollectingUnrelatedPlants(string partName)
    {
        using var fixture = new Fixture();
        Renderer blocking = fixture.Wall(partName, new Vector3(0f, 1f, -2.5f));
        var untouched = new[]
        {
            fixture.Wall("PS_Plant_Olive_Leaves", new Vector3(0f, 1f, 3f)),
            fixture.Wall("PS_Plant_Olive_Stems", new Vector3(10f, 1f, -2.5f)),
            fixture.Wall("PS_Plant_OliveDecoration_Leaves", new Vector3(0f, 1f, -2.5f)),
            fixture.Wall("PS_Plant_Shelf_Leaves", new Vector3(0f, 1f, -2.5f)),
        }.ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
        Material[] original = blocking.sharedMaterials;
        fixture.Frame(10f, 0.3f);
        AssertFaded(blocking);
        AssertMaterialsRestored(untouched);
        fixture.RestoreFrame();
        CollectionAssert.AreEqual(original, blocking.sharedMaterials);
        blocking.transform.position = new Vector3(10f, 1f, -2.5f);
        fixture.Frame(11f, 0.4f);
        CollectionAssert.AreEqual(original, blocking.sharedMaterials,
            "The olive part must recover when it no longer covers the person.");
        AssertMaterialsRestored(untouched);
    }

    [Test]
    public void AuthoredOliveLeavesRevealThePersonWalkingBehindThemAndRecover()
    {
        using var fixture = new Fixture();
        GameObject room = fixture.Room();
        var original = room.GetComponentsInChildren<Renderer>(true)
            .ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
        Renderer leaves = original.Keys.Single(renderer => renderer.name == "V4_Olive_Baked");
        float ownerX = leaves.bounds.center.x;
        float ownerZ = leaves.bounds.min.z - 0.35f;
        fixture.MoveOwnerAndCamera(ownerX, ownerZ);
        Assert.That(Intersects(leaves, fixture.Camera.transform.position, fixture.Body.bounds.center), Is.True,
            "The shipped botanical mesh must actually cover this walking person's sight line.");
        fixture.Frame(10f, 0.3f);
        AssertFaded(leaves);
        fixture.RestoreFrame();
        AssertMaterialsRestored(original);

        fixture.MoveOwnerAndCamera(0f, 0f);
        fixture.Frame(11f, 0.4f);
        foreach (Renderer renderer in original.Keys.Where(renderer =>
                     renderer.name.StartsWith("V4_Olive_", StringComparison.Ordinal)))
            CollectionAssert.AreEqual(original[renderer], renderer.sharedMaterials,
                renderer.name + " must remain intact away from the person's sight line.");
        fixture.RestoreFrame();
        AssertMaterialsRestored(original);
        Assert.That(leaves.GetComponentsInChildren<Collider>(true), Is.Empty,
            "Revealing the person must not add plant physics or change walking.");
    }

    [TestCase("PS_Sofa_Seat")]
    [TestCase("PS_Sofa_Back")]
    [TestCase("PS_Sofa_Arm")]
    [TestCase("V2_Sofa_Baked")]
    public void SofaPartsFadeOnlyBetweenTheCameraAndPersonAndRestore(string partName)
    {
        using var fixture = new Fixture();
        Renderer blocking = fixture.Wall(partName, new Vector3(0f, 1f, -2.5f));
        var untouched = new[]
        {
            fixture.Wall("PS_Sofa_Seat", new Vector3(0f, 1f, 3f)),
            fixture.Wall("PS_Sofa_Back", new Vector3(10f, 1f, -2.5f)),
            fixture.Wall("PS_SofaPoster", new Vector3(0f, 1f, -2.5f)),
        }.ToDictionary(renderer => renderer, renderer => renderer.sharedMaterials);
        Material[] original = blocking.sharedMaterials;
        fixture.Frame(10f, 0.3f);
        AssertFaded(blocking);
        AssertMaterialsRestored(untouched);
        fixture.RestoreFrame();
        CollectionAssert.AreEqual(original, blocking.sharedMaterials,
            "The sofa's original material must be restored before another camera renders.");
        blocking.transform.position = new Vector3(10f, 1f, -2.5f);
        fixture.Frame(11f, 0.4f);
        CollectionAssert.AreEqual(original, blocking.sharedMaterials);
        AssertMaterialsRestored(untouched);
    }

    [Test]
    public void HollowFramesFurnitureGroundAndDisabledRenderersKeepTheirMaterials()
    {
        using var fixture = new Fixture();
        var unchanged = new List<(Renderer Renderer, Material Material)>();
        foreach (string name in new[] { "PS_Window_Frame", "PS_Wall_Skirting", "PS_Desk_Top", "PS_Floor",
                     "V2_Floor_Baked", "V2_Rug_Baked", "V2_Window_Glass", "V2_Oak_Skirting_Side" })
        {
            Renderer renderer = fixture.Wall(name, new Vector3(0f, 1f, -2.5f));
            unchanged.Add((renderer, renderer.sharedMaterial));
        }
        Renderer disabled = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        disabled.enabled = false;
        unchanged.Add((disabled, disabled.sharedMaterial));
        Renderer inactive = fixture.Wall("PS_Wall_Right", new Vector3(0f, 1f, -2.5f));
        inactive.gameObject.SetActive(false);
        unchanged.Add((inactive, inactive.sharedMaterial));
        Material bodyMaterial = fixture.Body.sharedMaterial;
        fixture.Frame(10f, 0.3f);
        foreach (var value in unchanged)
            Assert.That(value.Renderer.sharedMaterial, Is.SameAs(value.Material), value.Renderer.name);
        Assert.That(fixture.Body.sharedMaterial, Is.SameAs(bodyMaterial));
        Assert.That(disabled.enabled, Is.False);
        Assert.That(inactive.gameObject.activeSelf, Is.False);
    }

    [Test]
    public void BrieflyClearingTheWallHoldsTheFadeThenRestoresItSmoothly()
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        Material original = wall.sharedMaterial;
        fixture.Frame(10f, 0.3f);
        float occludedOpacity = Opacity(wall);
        fixture.RestoreFrame();
        wall.transform.position = new Vector3(10f, 1f, -2.5f);
        fixture.Frame(10.05f, 0.05f);
        Assert.That(Opacity(wall), Is.EqualTo(occludedOpacity).Within(0.005f),
            "A short edge crossing should not make the wall flash opaque.");
        fixture.RestoreFrame();
        fixture.Frame(10.2f, 0.05f);
        Assert.That(Opacity(wall), Is.GreaterThan(occludedOpacity).And.LessThan(1f));
        fixture.RestoreFrame();
        fixture.Frame(10.6f, 0.4f);
        Assert.That(wall.sharedMaterial, Is.SameAs(original));
    }

    [Test]
    public void LosingTheTargetOrDisablingTheDirectorRestoresEveryWall()
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        Material original = wall.sharedMaterial;
        fixture.Frame(10f, 0.3f);
        AssertFaded(wall);
        Invoke(fixture.Director, "UpdateTarget", (object)null);
        fixture.Frame(10.1f, 0.1f);
        Assert.That(wall.sharedMaterial, Is.SameAs(original));
        Invoke(fixture.Director, "UpdateTarget", fixture.Owner.transform);
        fixture.Frame(11f, 0.3f);
        AssertFaded(wall);
        ((Behaviour)fixture.Director).enabled = false;
        fixture.Frame(11.1f, 0.1f);
        Assert.That(wall.sharedMaterial, Is.SameAs(original));
    }

    [Test]
    public void DisablingAndDestroyingTheEffectRestoreMaterialsWithoutASecondRender()
    {
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        Material original = wall.sharedMaterial;
        fixture.Frame(10f, 0.3f);
        AssertFaded(wall);
        ((Behaviour)fixture.Effect).enabled = false;
        Assert.That(wall.sharedMaterial, Is.SameAs(original));
        ((Behaviour)fixture.Effect).enabled = true;
        fixture.Frame(11f, 0.3f);
        AssertFaded(wall);
        UnityEngine.Object.DestroyImmediate(fixture.Effect);
        Assert.That(wall.sharedMaterial, Is.SameAs(original));
    }



    [Test]
    public void RenderedDitherRevealsThePersonAndDoesNotLeakIntoAnotherCamera()
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
            Assert.Ignore("Pixel verification needs Unity to run without -nographics.");
        using var fixture = new Fixture();
        Renderer wall = fixture.Wall("PS_Wall_Left", new Vector3(0f, 1f, -2.5f));
        Material original = wall.sharedMaterial;
        fixture.Body.sharedMaterial.color = Color.red;
        fixture.Body.sharedMaterial.SetColor("_EmissionColor", Color.red);
        fixture.Body.sharedMaterial.EnableKeyword("_EMISSION");
        wall.sharedMaterial.color = Color.green;
        wall.sharedMaterial.SetColor("_EmissionColor", Color.green);
        wall.sharedMaterial.EnableKeyword("_EMISSION");
        Texture2D blocked = null;
        Texture2D revealed = null;
        Texture2D otherCameraImage = null;
        GameObject otherCameraObject = new GameObject("UnmodifiedOcclusionObserver");
        try
        {
            ((Behaviour)fixture.Effect).enabled = false;
            blocked = Capture(fixture.Camera);
            ((Behaviour)fixture.Effect).enabled = true;
            fixture.Frame(Time.realtimeSinceStartup, 0.3f);
            fixture.RestoreFrame();
            revealed = Capture(fixture.Camera);
            Assert.That(CountRed(revealed), Is.GreaterThan(CountRed(blocked) + 500),
                "The shader must reveal actual pixels of the person through the obstructing wall.");
            Assert.That(wall.sharedMaterial, Is.SameAs(original));
            Camera observer = otherCameraObject.AddComponent<Camera>();
            observer.CopyFrom(fixture.Camera);
            observer.transform.SetPositionAndRotation(fixture.Camera.transform.position,
                fixture.Camera.transform.rotation);
            otherCameraImage = Capture(observer);
            Assert.That(CountRed(otherCameraImage), Is.LessThanOrEqualTo(CountRed(blocked) + 20),
                "An unrelated camera must still render the wall using its original material.");
            System.IO.File.WriteAllBytes(System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "maaso-world-occlusion-blocked.png"), blocked.EncodeToPNG());
            System.IO.File.WriteAllBytes(System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "maaso-world-occlusion-revealed.png"), revealed.EncodeToPNG());
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(otherCameraObject);
            if (blocked != null) UnityEngine.Object.DestroyImmediate(blocked);
            if (revealed != null) UnityEngine.Object.DestroyImmediate(revealed);
            if (otherCameraImage != null) UnityEngine.Object.DestroyImmediate(otherCameraImage);
        }
    }

    private static int CountRed(Texture2D image)
    {
        int count = 0;
        for (int y = 72; y < 184; y++)
            for (int x = 88; x < 168; x++)
            {
                Color color = image.GetPixel(x, y);
                if (color.r > 0.35f && color.r > color.g * 1.8f && color.r > color.b * 1.8f)
                    count++;
            }
        return count;
    }

    private static bool IsMagenta(Color32 pixel) =>
        pixel.r > 128 && pixel.b > 128 && pixel.g < 90 &&
        pixel.r > pixel.g * 2 && pixel.b > pixel.g * 2;

    private static void AssertMaterialsRestored(Dictionary<Renderer, Material[]> originals)
    {
        foreach (var pair in originals)
            CollectionAssert.AreEqual(pair.Value, pair.Key.sharedMaterials, pair.Key.name);
    }

    private static Texture2D Capture(Camera camera, int width = 256, int height = 256)
    {
        RenderTexture previous = RenderTexture.active;
        RenderTexture previousTarget = camera.targetTexture;
        RenderTexture target = RenderTexture.GetTemporary(width, height, 24, RenderTextureFormat.ARGB32);
        try
        {
            camera.targetTexture = target;
            camera.Render();
            RenderTexture.active = target;
            var result = new Texture2D(width, height, TextureFormat.RGBA32, false);
            result.ReadPixels(new Rect(0, 0, width, height), 0, 0);
            result.Apply();
            return result;
        }
        finally
        {
            camera.targetTexture = previousTarget;
            RenderTexture.active = previous;
            RenderTexture.ReleaseTemporary(target);
        }
    }

    private static bool Intersects(Renderer renderer, Vector3 origin, Vector3 target) =>
        (bool)WorldType("WorldCameraOcclusion").GetMethod("IntersectsSightLine",
            BindingFlags.Public | BindingFlags.Static).Invoke(null, new object[] { renderer, origin, target });

    private static float Opacity(Renderer renderer)
    {
        Assert.That(renderer.sharedMaterial.HasProperty("_OcclusionOpacity"), Is.True,
            renderer.name + " should use the temporary occlusion material.");
        return renderer.sharedMaterial.GetFloat("_OcclusionOpacity");
    }

    private static void AssertFaded(Renderer renderer) =>
        Assert.That(Opacity(renderer), Is.InRange(0.075f, 0.95f), renderer.name);

    private static Type WorldType(string name)
    {
        Type type = Type.GetType($"Maaso.World.{name}, Assembly-CSharp");
        Assert.That(type, Is.Not.Null, name);
        return type;
    }

    private static object Invoke(object target, string name, params object[] arguments) =>
        target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.Public)
            .Invoke(target, arguments);

    private static object InvokePrivate(object target, string name, params object[] arguments) =>
        target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(target, arguments);

    private static void SetField(object target, string name, object value) =>
        target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)
            .SetValue(target, value);

    private static T Property<T>(object target, string name) =>
        (T)target.GetType().GetProperty(name).GetValue(target);

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Stage = new("WorldOcclusionFixture");
        public readonly GameObject Owner;
        public readonly Camera Camera;
        public readonly Component Map;
        public readonly Component Director;
        public readonly Component Effect;
        public readonly Renderer Body;
        public readonly Transform Visuals;
        private readonly List<Material> materials = new();

        public Fixture()
        {
            var mapRoot = new GameObject("FixtureMap");
            mapRoot.transform.SetParent(Stage.transform, false);
            Map = (Component)WorldType("PersistentWorldMapController")
                .GetMethod("BuildDefaultMap", BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, new object[] { mapRoot });
            Invoke(Map, "SetWorldActive", true);
            Visuals = mapRoot.transform.Find("PersistentEnvironmentRoot/BaseVisuals/WhiteboxVisuals");
            Owner = new GameObject("OcclusionOwner");
            Owner.transform.SetParent(Stage.transform, false);
            Body = Primitive("AvatarBody", Owner.transform, new Vector3(0f, 1f, 0f),
                new Vector3(0.7f, 1.8f, 0.5f));
            var cameraRoot = new GameObject("OcclusionCamera");
            cameraRoot.transform.SetParent(Stage.transform, false);
            Camera = cameraRoot.AddComponent<Camera>();
            Camera.enabled = false;
            Camera.clearFlags = CameraClearFlags.SolidColor;
            Camera.backgroundColor = Color.black;
            Camera.cullingMask = 1 << 30;
            Camera.aspect = 1f;
            Camera.fieldOfView = 35f;
            Camera.nearClipPlane = 0.05f;
            Camera.farClipPlane = 30f;
            Camera.allowHDR = false;
            Camera.allowMSAA = false;
            Camera.transform.SetPositionAndRotation(new Vector3(0f, 1f, -5f), Quaternion.identity);
            Director = cameraRoot.AddComponent(WorldType("WorldCameraDirector"));
            Assert.That(Invoke(Director, "EnterWorld", Camera, null, Owner.transform, null), Is.EqualTo(true));
            Effect = cameraRoot.GetComponent(WorldType("WorldCameraOcclusion"));
            Assert.That(Effect, Is.Not.Null);
            SetField(Effect, "map", Map);
        }

        public Renderer Wall(string name, Vector3 position, Transform parent = null) =>
            Primitive(name, parent != null ? parent : Visuals, position, new Vector3(4f, 3f, 0.2f));

        public GameObject Room()
        {
            GameObject prefab = Resources.Load<GameObject>("PersonalSpaceModel");
            Assert.That(prefab, Is.Not.Null);
            GameObject room = UnityEngine.Object.Instantiate(prefab, Visuals, false);
            foreach (Transform child in room.GetComponentsInChildren<Transform>(true))
                child.gameObject.layer = 30;
            Collider walkableFloor = room.GetComponentsInChildren<Collider>(true)
                .SingleOrDefault(value => value.name == "V4WalkableFloor");
            Assert.That(walkableFloor, Is.TypeOf<MeshCollider>(),
                "The V4 room needs its real walkable-floor collider; visual occluders need none.");
            Assert.That(walkableFloor.enabled, Is.True);
            return room;
        }

        public void MoveOwnerAndCamera(float x, float z)
        {
            Owner.transform.position = new Vector3(x, 0f, z);
            Camera.aspect = 9f / 16f;
            Camera.fieldOfView = 51f;
            object pose = WorldType("WorldCameraDirector").GetMethod("CalculateOwnerBirdseyePose",
                    BindingFlags.Public | BindingFlags.Static)
                .Invoke(null, new object[] { Owner.transform.position, Camera.fieldOfView, Camera.aspect });
            Camera.transform.SetPositionAndRotation(Property<Vector3>(pose, "Position"),
                Property<Quaternion>(pose, "Rotation"));
        }

        private Renderer Primitive(string name, Transform parent, Vector3 position, Vector3 scale)
        {
            GameObject value = GameObject.CreatePrimitive(PrimitiveType.Cube);
            value.name = name;
            value.transform.SetParent(parent, false);
            value.transform.localPosition = position;
            value.transform.localScale = scale;
            value.layer = 30;
            UnityEngine.Object.DestroyImmediate(value.GetComponent<Collider>());
            var material = new Material(Shader.Find("Standard"));
            materials.Add(material);
            Renderer renderer = value.GetComponent<Renderer>();
            renderer.sharedMaterial = material;
            return renderer;
        }

        public void Frame(float now, float deltaTime) =>
            InvokePrivate(Effect, "PrepareFrame", now, deltaTime);

        public void RestoreFrame() => InvokePrivate(Effect, "RestoreRenderers");

        public void Dispose()
        {
            UnityEngine.Object.DestroyImmediate(Stage);
            foreach (Material material in materials)
                if (material != null) UnityEngine.Object.DestroyImmediate(material);
        }
    }
}
