using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

public sealed class InputUpperBodyFramingTests
{
    private const BindingFlags Instance = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    private static Type Avatar(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static object Call(object target, string name, params object[] args) => target.GetType()
        .GetMethods(Instance).Single(method => method.Name == name && method.GetParameters().Length == args.Length)
        .Invoke(target, args);
    private static T Property<T>(object target, string name) =>
        (T)target.GetType().GetProperty(name).GetValue(target);

    [TestCase(393, 852)]
    [TestCase(320, 800)]
    public void PublishedHomeUpperBodyKeepsHeadAndChestVisibleWithoutForegroundRoomBars(int width, int height)
    {
        Scene scene = EditorSceneManager.NewPreviewScene();
        bool oldBackfaces = Physics.queriesHitBackfaces;
        try
        {
            var holder = new GameObject("Input upper body preview");
            SceneManager.MoveGameObjectToScene(holder, scene);
            GameObject model = AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm");
            Assert.That(model, Is.Not.Null);
            GameObject actor = Object.Instantiate(model, holder.transform);
            Animator animator = actor.GetComponentInChildren<Animator>();
            Assert.That(animator.avatar.isHuman, Is.True);
            animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            animator.applyRootMotion = false;
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.Rebind(); animator.Play("idle_shrug", 0, .25f); animator.Update(0);
            GameObject room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"), holder.transform);
            Component map = room.GetComponent(Type.GetType("Maaso.World.PersistentWorldMapController, Assembly-CSharp", true));
            var cameraObject = new GameObject("Input upper body camera");
            SceneManager.MoveGameObjectToScene(cameraObject, scene);
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.scene = scene; camera.aspect = (float)width / height;
            camera.fieldOfView = 37.5f; camera.nearClipPlane = .3f;
            camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = Color.white;
            Component framing = camera.gameObject.AddComponent(Avatar("FrontFullBodyCamera"));
            framing.GetType().GetProperty("TargetRoot").SetValue(framing, actor.transform);
            Assert.That(Call(map, "AlignHomeAvatar", actor.transform), Is.True);
            Call(framing, "SetHomeViewReference", Property<Transform>(map, "HomeCameraReference"));
            object rig = framing.GetType().GetField("entrySafetyRig", Instance).GetValue(framing);
            Assert.That(rig, Is.Not.Null);
            object navigation = Property<object>(rig, "Navigation");
            Vector3 grounded = actor.transform.position;
            Transform chest = animator.GetBoneTransform(HumanBodyBones.Chest);
            Assert.That(chest, Is.Not.Null);
            // Temporary exact-triangle probes never alter imported meshes or
            // materials. Ignore geometry behind the actual near clipping plane.
            var probes = room.GetComponentsInChildren<MeshFilter>().Where(mesh =>
                mesh.sharedMesh != null && mesh.GetComponent<Renderer>()?.enabled == true).Select(mesh =>
            {
                var probe = new GameObject(mesh.name + " ray probe");
                probe.transform.SetParent(mesh.transform, false);
                var collider = probe.AddComponent<MeshCollider>(); collider.sharedMesh = mesh.sharedMesh;
                return collider;
            }).ToArray();
            Physics.queriesHitBackfaces = true; Physics.SyncTransforms();
            foreach (string mode in new[] { "three_quarter", "upper_body" })
            {
                // Reproduce the rejected keyboard shot, then the restored
                // keyboard-independent upper-body viewport.
                Call(framing, "SetViewportSafeArea", .20f, mode == "three_quarter" ? .45f : .14f);
                Call(framing, "SetFramingMode", mode); Call(framing, "FrameNow");
                for (int frame = 0; frame < 360; frame++) Call(framing, "AdvanceFraming", 1f / 60f);
                string label = $"Joy {width}x{height} {mode}";
                int blocked = TorsoOcclusion(camera, chest, actor.transform.right, probes, label);
                TestContext.WriteLine($"{label}: camera={camera.transform.position:F4}, FOV={camera.fieldOfView:F3}, torso blocked={blocked}/153");
                if (width == 393) Capture(camera, scene, width, height, mode);
                if (mode == "three_quarter") continue; // Rejected shot is diagnostic evidence only.
                Assert.That(Property<string>(framing, "FramingMode"), Is.EqualTo("upper_body"));
                Assert.That(Property<float>(framing, "VisibleBodyRatio"), Is.EqualTo(.50f));
                Assert.That(actor.transform.position, Is.EqualTo(grounded));
                Assert.That(Call(navigation, "ContainsCamera", camera.transform.position, .08f), Is.True);
                Assert.That(blocked, Is.Zero, "Published room triangles must not cross the upper-body torso.");
                HumanBodyBones upper = animator.GetBoneTransform(HumanBodyBones.UpperChest) != null
                    ? HumanBodyBones.UpperChest : HumanBodyBones.Neck;
                foreach (HumanBodyBones bone in new[] { HumanBodyBones.Head, upper, HumanBodyBones.Chest, HumanBodyBones.LeftHand, HumanBodyBones.RightHand })
                {
                    Transform joint = animator.GetBoneTransform(bone);
                    Assert.That(joint, Is.Not.Null, label + " " + bone);
                    Vector3 viewport = camera.WorldToViewportPoint(joint.position);
                    TestContext.WriteLine($"{label} {bone}: viewport={viewport:F4}");
                    Assert.That(viewport.z, Is.GreaterThan(camera.nearClipPlane), label + " " + bone);
                    if (bone is HumanBodyBones.Chest or HumanBodyBones.LeftHand or HumanBodyBones.RightHand) continue;
                    Assert.That(viewport.x, Is.InRange(.05f, .95f), label + " " + bone);
                    Assert.That(viewport.y, Is.InRange(.14f, .80f), label + " " + bone);
                }
            }
        }
        finally
        {
            Physics.queriesHitBackfaces = oldBackfaces;
            EditorSceneManager.ClosePreviewScene(scene);
        }
    }

    private static int TorsoOcclusion(Camera camera, Transform chest, Vector3 right, MeshCollider[] probes, string label)
    {
        int blocked = 0;
        var names = new Dictionary<string, int>();
        for (int row = 0; row < 17; row++)
        for (int column = 0; column < 9; column++)
        {
            Vector3 endpoint = chest.position + right * Mathf.Lerp(-.14f, .14f, column / 8f) +
                Vector3.up * Mathf.Lerp(-.25f, .25f, row / 16f);
            Vector3 direction = (endpoint - camera.transform.position).normalized;
            float near = camera.nearClipPlane / Vector3.Dot(direction, camera.transform.forward) + .001f;
            Vector3 start = camera.transform.position + direction * near;
            float nearest = Vector3.Distance(start, endpoint) - .02f;
            string hitName = null;
            foreach (MeshCollider probe in probes)
            {
                if (!probe.Raycast(new Ray(start, direction), out RaycastHit hit, nearest)) continue;
                nearest = hit.distance; hitName = probe.transform.parent.name;
            }
            if (hitName == null) continue;
            blocked++; names[hitName] = names.TryGetValue(hitName, out int count) ? count + 1 : 1;
        }
        foreach (var hit in names) TestContext.WriteLine($"{label}: foreground={hit.Key}, rays={hit.Value}");
        return blocked;
    }

    private static void Capture(Camera camera, Scene scene, int width, int height, string mode)
    {
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
        { TestContext.WriteLine("PNG skipped: no GPU; geometry assertions still ran."); return; }
        var light = new GameObject("Input upper body key light").AddComponent<Light>();
        light.type = LightType.Directional; light.intensity = 1.1f;
        light.transform.rotation = Quaternion.Euler(45f, -30f, 0f);
        SceneManager.MoveGameObjectToScene(light.gameObject, scene);
        RenderTexture previousTarget = camera.targetTexture, previousActive = RenderTexture.active;
        var target = new RenderTexture(width, height, 24, RenderTextureFormat.ARGB32);
        var image = new Texture2D(width, height, TextureFormat.RGBA32, false);
        try
        {
            camera.targetTexture = target; camera.Render(); RenderTexture.active = target;
            image.ReadPixels(new Rect(0, 0, width, height), 0, 0); image.Apply();
            const string output = "/private/tmp/maaso-input-upper-body-20261017";
            Directory.CreateDirectory(output);
            string path = Path.Combine(output, $"joy-{width}x{height}-{mode}.png");
            File.WriteAllBytes(path, image.EncodeToPNG()); TestContext.WriteLine("Input framing portrait: " + path);
        }
        finally
        {
            camera.targetTexture = previousTarget; RenderTexture.active = previousActive;
            Object.DestroyImmediate(target); Object.DestroyImmediate(image); Object.DestroyImmediate(light.gameObject);
        }
    }
}
