using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UniVRM10;
using UnityEngine.TestTools;
using System.Text.RegularExpressions;
using Object = UnityEngine.Object;

public sealed class AvatarPhoneInteractionTests
{
    private static Type TypeOf(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);

    [Test]
    public void ReadingTakesOutDetailedPhoneAndCompletesAfterHandArrives()
    {
        using var f = new Fixture();
        f.Execute("reading");
        Assert.That(f.Results, Is.Empty);
        f.Advance(.45f);
        Assert.That(f.Results, Is.Empty);
        Vector3 midway = f.Phone.transform.position;
        f.Advance(1.1f);
        Assert.That(f.Results.Single().ok, Is.True);
        Assert.That(f.Phone.activeSelf, Is.True);
        Assert.That(Vector3.Distance(midway, f.Phone.transform.position), Is.GreaterThan(.03f));
        Assert.That(f.Phone.GetComponentsInChildren<MeshRenderer>().Length, Is.GreaterThan(30));
        Assert.That(f.Phone.transform.Find("Wide camera glass"), Is.Not.Null);
        Assert.That(f.Phone.transform.Find("Active display"), Is.Not.Null);
        Assert.That(f.Phone.transform.Find("Power control"), Is.Not.Null);
        AssertHandAtGripTarget(f, true);
    }

    [Test]
    public void ReplyingAddsOtherHandAndAnimatedThumbWithoutMovingRootOrLegs()
    {
        using var f = new Fixture();
        Vector3 root = f.Root.position; Quaternion rootRotation = f.Root.rotation;
        Transform leg = f.Bone(HumanBodyBones.LeftUpperLeg);
        Quaternion legRotation = leg.localRotation;
        f.Execute("reading"); f.Advance(1.1f);
        f.Execute("replying", now: 1.2f); f.Advance(1.7f);
        AssertHandAtGripTarget(f, true);
        AssertHandAtGripTarget(f, false);
        Quaternion thumb = f.Bone(HumanBodyBones.RightThumbDistal).localRotation;
        f.Advance(1.85f);
        Assert.That(Quaternion.Angle(thumb, f.Bone(HumanBodyBones.RightThumbDistal).localRotation), Is.GreaterThan(1f));
        Assert.That(f.Root.position, Is.EqualTo(root)); Assert.That(f.Root.rotation, Is.EqualTo(rootRotation));
        Assert.That(leg.localRotation, Is.EqualTo(legRotation));
    }

    [TestCase(0f, .8f)]
    [TestCase(73f, 1.2f)]
    public void GripTargetsStayAccurateWhenTheHumanoidIsRotatedAndUniformlyScaled(float yaw, float scale)
    {
        using var f = new Fixture();
        f.Root.rotation = Quaternion.AngleAxis(yaw, Vector3.up) * f.Root.rotation;
        f.Root.localScale *= scale;
        f.Root.position += new Vector3(.4f, 0f, -.2f);
        Vector3 rootPosition = f.Root.position;
        Quaternion legRotation = f.Bone(HumanBodyBones.LeftUpperLeg).localRotation;
        f.Execute("reading");
        f.Advance(1.1f);
        AssertHandAtGripTarget(f, true);
        f.Execute("replying", now: 1.2f);
        f.Advance(1.8f);
        AssertHandAtGripTarget(f, true);
        AssertHandAtGripTarget(f, false);
        Assert.That(f.Root.position, Is.EqualTo(rootPosition));
        Assert.That(f.Bone(HumanBodyBones.LeftUpperLeg).localRotation, Is.EqualTo(legRotation));
    }

    [Test]
    public void NoneReturnsToHipHidesAndRestoresOwnedPose()
    {
        using var f = new Fixture();
        Quaternion hand = f.Bone(HumanBodyBones.LeftUpperArm).localRotation;
        f.Execute("reading"); f.Advance(1.1f); Vector3 held = f.Phone.transform.position;
        f.Execute("none", now: 1.2f); f.Advance(1.65f);
        Assert.That(f.Phone.transform.position.y, Is.LessThan(held.y));
        Assert.That(f.Phone.activeSelf, Is.True);
        f.Advance(2.1f);
        Assert.That(f.Phone.activeSelf, Is.False); Assert.That((bool)f.Controller.OwnsHands, Is.False);
        Assert.That(Quaternion.Angle(hand, f.Bone(HumanBodyBones.LeftUpperArm).localRotation), Is.LessThan(.05f));
        Assert.That(f.Results.Last().ok, Is.True);
    }

    [TestCase("none")]
    [TestCase("replying")]
    [TestCase("reading")]
    public void OlderInteractionCannotModifyCurrentPhone(string stalePhase)
    {
        using var f = new Fixture();
        f.Execute("reading", id: "older"); f.Advance(1.1f);
        f.Execute("reading", id: "current", now: 1.2f); f.Advance(2.4f);
        f.Execute(stalePhase, id: "older", now: 2.5f);
        Assert.That(f.Results.Last().ok, Is.False);
        Assert.That((string)f.Controller.InteractionId, Is.EqualTo("current"));
        Assert.That(f.Phone.activeSelf, Is.True);
    }

    [Test]
    public void ExpiredCommandAndReorderedSequenceAreRejected()
    {
        using var f = new Fixture();
        f.Execute("reading", expires: 500);
        Assert.That(f.Results.Last().ok, Is.False);
        f.Execute("reading", sequence: 10); f.Advance(1.1f);
        f.Execute("none", sequence: 9, now: 1.2f);
        Assert.That(f.Results.Last().ok, Is.False); Assert.That(f.Phone.activeSelf, Is.True);
    }

    [Test]
    public void ResetRejectsPendingAndRetiresOldIdForRendererBoundary()
    {
        using var f = new Fixture();
        f.Execute("reading"); f.Advance(.4f);
        f.Controller.Reset("model_replaced");
        Assert.That(f.Results.Last().ok, Is.False);
        Assert.That(f.Results.Last().code, Is.EqualTo("model_replaced"));
        Assert.That((bool)f.Controller.OwnsHands, Is.False);
        f.Execute("reading");
        Assert.That(f.Results.Last().code, Is.EqualTo("stale_interaction"));
    }

    [Test]
    public void TimeoutClearsPropAndPoseEvenAfterAnAcknowledgedReading()
    {
        using var f = new Fixture();
        f.Execute("reading"); f.Advance(1.1f); f.Advance(46f);
        Assert.That((bool)f.Controller.OwnsHands, Is.False); Assert.That(f.Phone == null, Is.True);
    }

    [Test]
    public void OverlayDoesNotAccumulateOrRestoreOverNewAnimatorPose()
    {
        using var f = new Fixture();
        f.Execute("reading"); f.Advance(1.1f);
        Quaternion first = f.Bone(HumanBodyBones.Head).localRotation;
        for (int index = 0; index < 60; index++) f.Advance(1.2f + index * .01f);
        Assert.That(Quaternion.Angle(first, f.Bone(HumanBodyBones.Head).localRotation), Is.LessThan(.01f));
        Quaternion newAnimated = Quaternion.Euler(8, 12, 3);
        f.Bone(HumanBodyBones.Head).localRotation = newAnimated;
        f.Controller.Reset("disabled");
        Assert.That(f.Bone(HumanBodyBones.Head).localRotation, Is.EqualTo(newAnimated));
    }

    [Test]
    public void ActualVrmReadingReplyingAndPocketReturnRenderDifferently()
    {
        if (SystemInfo.graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Null)
            Assert.Ignore("Image verification requires a real graphics device. Run this test without -nographics; joint, grip, visibility and return tests still run headlessly.");
        using var f = new Fixture();
        var images = new List<byte[]>();
        images.Add(f.Capture("rest"));
        f.Execute("reading"); f.Advance(.45f); images.Add(f.Capture("pickup"));
        f.Advance(1.1f); images.Add(f.Capture("reading"));
        f.Execute("replying", now: 1.2f); f.Advance(1.8f); images.Add(f.Capture("replying"));
        f.Execute("none", now: 2f); f.Advance(2.95f); images.Add(f.Capture("returned"));
        Assert.That(images[0].SequenceEqual(images[2]), Is.False);
        Assert.That(images[2].SequenceEqual(images[3]), Is.False);
        Assert.That(images[3].SequenceEqual(images[4]), Is.False);
    }

    [Test]
    public void MouthExpressionAndWalkingLegPoseStayOwnedByTheirExistingRuntime()
    {
        using var f = new Fixture();
        f.Animator.Play("standard_walk"); f.Animator.Update(.2f);
        Quaternion leg = f.Bone(HumanBodyBones.LeftUpperLeg).localRotation;
        f.Vrm.Runtime.Expression.SetWeight(ExpressionKey.Aa, .63f);
        f.Execute("reading"); f.Advance(1.1f);
        f.Vrm.Runtime.Process();
        Assert.That(f.Vrm.Runtime.Expression.GetWeight(ExpressionKey.Aa), Is.EqualTo(.63f).Within(.001f));
        Assert.That(Quaternion.Angle(leg, f.Bone(HumanBodyBones.LeftUpperLeg).localRotation), Is.LessThan(.01f));
        f.Controller.Reset("finished"); f.Vrm.Runtime.Process();
        Assert.That(f.Vrm.Runtime.Expression.GetWeight(ExpressionKey.Aa), Is.EqualTo(.63f).Within(.001f));
    }

    [Test]
    public void ReceiverDispatchesPhoneAndDisableClearsItsIndependentOverlay()
    {
        using var f = new Fixture();
        Component receiver = Object.FindAnyObjectByType(TypeOf("UnityAvatarCommandReceiver")) as Component;
        Type receiverType = receiver.GetType();
        receiverType.GetMethod("OnFlutterCommand").Invoke(receiver, new object[] {
            "{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}" });
        string command = "{\"requestId\":\"receiver-phone\",\"interactionId\":\"receiver-conversation\",\"phase\":\"reading\",\"sequence\":1,\"expiresAtMs\":" +
            (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 5000) + "}";
        string packet = "{\"method\":\"setPhoneInteraction\",\"json\":" + Escape(command) + "}";
        receiverType.GetMethod("OnFlutterCommand").Invoke(receiver, new object[] { packet });
        dynamic phone = receiverType.GetField("phoneInteraction", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(receiver);
        Assert.That(phone, Is.Not.Null);
        phone.Advance(Time.realtimeSinceStartup + 1.1f, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 1100);
        Assert.That((bool)phone.OwnsHands, Is.True);
        receiverType.GetMethod("OnDisable", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(receiver, null);
        Assert.That((bool)phone.OwnsHands, Is.False);
        Assert.That((GameObject)phone.Phone == null, Is.True);
    }

    private static void AssertHandAtGripTarget(Fixture f, bool left)
    {
        // A wrist is deliberately one measured palm length below the contact point.
        // Its distance to the phone centre is not an IK error and varies by avatar.
        // Compare the physical solved wrist with the requested grip target instead;
        // this catches intermediate-joint/axis mistakes without changing tolerances.
        object controller = f.Controller;
        MethodInfo targetMethod = controller.GetType().GetMethod("GripWrist", BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.That(targetMethod, Is.Not.Null);
        Vector3 target = (Vector3)targetMethod.Invoke(controller,
            new object[] { left, f.Phone.transform.position, f.Phone.transform.rotation });
        Vector3 actual = f.Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand).position;
        Assert.That(Vector3.Distance(actual, target), Is.LessThan(.001f),
            $"{(left ? "Left" : "Right")} wrist failed to reach its palm-calibrated phone grip target.");
    }

    private static string Escape(string text) => "\"" + text.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    private sealed class Fixture : IDisposable
    {
        public readonly Transform Root;
        public readonly Animator Animator;
        public readonly dynamic Controller;
        public readonly List<dynamic> Results = new();
        private int nextSequence;
        private readonly Vrm10Instance vrm;
        public Vrm10Instance Vrm => vrm;
        public GameObject Phone => (GameObject)Controller.Phone;
        public Fixture()
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Root = GameObject.Find("MaasoDefaultAvatar").transform;
            Animator = Root.GetComponentInChildren<Animator>();
            vrm = Root.GetComponentInChildren<Vrm10Instance>();
            // Unity logs UniVRM's EditMode material access once per material slot.
            int materialAccessCount = vrm.GetComponentsInChildren<Renderer>()
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .Sum(renderer => renderer.sharedMaterials.Length);
            for (int index = 0; index < materialAccessCount; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            vrm.Runtime.Process();
            Animator.Rebind(); Animator.Update(0f);
            Type resultType = TypeOf("AvatarPhoneResult");
            ParameterExpression value = Expression.Parameter(resultType);
            var callback = Expression.Lambda(typeof(Action<>).MakeGenericType(resultType),
                Expression.Call(Expression.Constant(Results), typeof(List<dynamic>).GetMethod("Add"), Expression.Convert(value, typeof(object))), value).Compile();
            Controller = Activator.CreateInstance(TypeOf("AvatarPhoneInteractionController"), callback);
        }
        public Transform Bone(HumanBodyBones bone) => Animator.GetBoneTransform(bone);
        public void Execute(string phase, string id = "conversation-one", float now = 0f, long? expires = null, int? sequence = null)
        {
            dynamic command = Activator.CreateInstance(TypeOf("AvatarPhoneCommand"));
            int seq = sequence ?? ++nextSequence;
            command.requestId = "phone-" + seq; command.interactionId = id; command.phase = phase;
            command.sequence = (long)seq; command.expiresAtMs = expires ?? (1000L + (long)(now * 1000) + 5000L);
            Controller.Execute(command, Root, now, 1000L + (long)(now * 1000));
        }
        public void Advance(float now) => Controller.Advance(now, 1000L + (long)(now * 1000));
        public byte[] Capture(string name)
        {
            // The default VRM's sleeve/twist constraints and spring bones must
            // process after the overlay, just as they do in production LateUpdate.
            vrm.Runtime.Process();
            string output = "/private/tmp/maaso-phone-interaction";
            Directory.CreateDirectory(output);
            var cameraObject = new GameObject("PhoneReviewCamera");
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.enabled = false; camera.useOcclusionCulling = false;
            camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = new Color(.91f, .91f, .88f);
            camera.fieldOfView = 34f; camera.nearClipPlane = .02f; camera.farClipPlane = 15f; camera.cullingMask = 1 << 30;
            Vector3 focus = Bone(HumanBodyBones.Chest).position - Root.up * .04f;
            camera.transform.position = focus + Root.forward * 1.9f + Root.right * .3f + Root.up * .18f;
            camera.transform.LookAt(focus);
            var target = new RenderTexture(900, 1100, 24); var image = new Texture2D(900, 1100, TextureFormat.RGBA32, false);
            var temporary = new List<GameObject>(); var meshes = new List<Mesh>();
            RenderTexture previous = RenderTexture.active;
            try
            {
                foreach (SkinnedMeshRenderer source in Root.GetComponentsInChildren<SkinnedMeshRenderer>())
                {
                    var mesh = new Mesh(); source.BakeMesh(mesh); meshes.Add(mesh);
                    var rendered = new GameObject("BakedActualPhonePose") { layer = 30 }; temporary.Add(rendered);
                    rendered.transform.SetParent(source.transform, false);
                    rendered.AddComponent<MeshFilter>().sharedMesh = mesh;
                    rendered.AddComponent<MeshRenderer>().sharedMaterials = source.sharedMaterials;
                }
                if (Phone != null) foreach (Transform child in Phone.GetComponentsInChildren<Transform>(true)) child.gameObject.layer = 30;
                target.Create(); camera.targetTexture = target; camera.Render(); RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, 900, 1100), 0, 0); image.Apply();
                byte[] png = image.EncodeToPNG(); File.WriteAllBytes(Path.Combine(output, name + ".png"), png);
                Color32[] colors = image.GetPixels32(); float darkest = 1f, brightest = 0f;
                for (int index = 0; index < colors.Length; index += 97)
                {
                    Color32 color = colors[index];
                    float luminance = (.2126f * color.r + .7152f * color.g + .0722f * color.b) / 255f;
                    darkest = Mathf.Min(darkest, luminance); brightest = Mathf.Max(brightest, luminance);
                }
                Assert.That(brightest - darkest, Is.GreaterThan(.05f), name + " capture is blank; it cannot prove a phone pose.");
                return png;
            }
            finally
            {
                foreach (GameObject item in temporary) Object.DestroyImmediate(item);
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
                RenderTexture.active = previous; Object.DestroyImmediate(cameraObject); Object.DestroyImmediate(target); Object.DestroyImmediate(image);
            }
        }
        public void Dispose() { Controller.Reset("test_complete"); EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single); }
    }
}
