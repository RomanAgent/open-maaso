using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class DesktopUnitySidecarArbiterTests
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    private GameObject host;
    private GameObject cameraHost;
    private Component bridge;
    private Component receiver;
    private SkinnedMeshRenderer face;
    private Mesh mesh;
    private readonly List<JObject> results = new();

    [SetUp]
    public void SetUp()
    {
        host = new GameObject("Sidecar arbiter fixture");
        cameraHost = new GameObject("Sidecar arbiter camera");
        cameraHost.tag = "MainCamera";
        cameraHost.AddComponent<Camera>();
        cameraHost.AddComponent(Type.GetType("Maaso.Avatar.FrontFullBodyCamera, Assembly-CSharp", true));
        var faceHost = new GameObject("Face");
        faceHost.transform.SetParent(host.transform, false);
        face = faceHost.AddComponent<SkinnedMeshRenderer>();
        mesh = new Mesh
        {
            vertices = new[] { Vector3.zero, Vector3.up, Vector3.right },
            triangles = new[] { 0, 1, 2 },
        };
        mesh.AddBlendShapeFrame("A", 100, new[] { Vector3.zero, Vector3.up * .01f, Vector3.zero },
            new Vector3[3], new Vector3[3]);
        face.sharedMesh = mesh;
        receiver = host.AddComponent(Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp", true));
        receiver.GetType().GetField("avatarRoot", PrivateInstance).SetValue(receiver, host.transform);
        receiver.GetType().GetField("faceRenderer", PrivateInstance).SetValue(receiver, face);
        Invoke(receiver, "EnsureAvatar");
        bridge = host.AddComponent(Type.GetType("Maaso.Avatar.DesktopUnitySidecarBridge, Assembly-CSharp", true));
        results.Clear();
        Application.logMessageReceived += CaptureReceiverResult;
    }

    [TearDown]
    public void TearDown()
    {
        Application.logMessageReceived -= CaptureReceiverResult;
        Object.DestroyImmediate(host);
        Object.DestroyImmediate(cameraHost);
        Object.DestroyImmediate(mesh);
    }

    [Test]
    public void CommandAndResetReachRealReceiverBeforeCaptureAndKeepExactReceipts()
    {
        JObject command = MouthCommand(1);
        JObject reset = ResetCommand();
        Enqueue("avatarArbiterCommand", command);
        Enqueue("avatarArbiterReset", reset);
        Invoke(bridge, "EnqueueInboundCommand", "command",
            new JObject { ["method"] = "acquire", ["generation"] = 8, ["profile"] = "compactHigh", ["targetFps"] = 30 });

        int captures = 0;
        Action<string, int> capture = (_, generation) =>
        {
            captures++;
            Assert.That(generation, Is.EqualTo(8));
            Assert.That(results.Count, Is.EqualTo(2), "Capture must wait for both real receiver acknowledgments.");
            Assert.That(face.GetBlendShapeWeight(0), Is.LessThan(1));
        };
        Drain(() => false, capture);
        Assert.That(results, Is.Empty, "Unavailable receiver must retain the fenced commands, not discard them.");
        Assert.That(captures, Is.Zero);
        Drain(() => true, capture);
        Assert.That(captures, Is.EqualTo(1));
        AssertReceipt(results[0], command, "avatarArbiterCommand", true, "");
        AssertReceipt(results[1], reset, "avatarArbiterReset", true, "");
        Assert.That(receiver.GetType().GetField("avatarArbiterOwnerToken", PrivateInstance).GetValue(receiver),
            Is.EqualTo(new string('B', 43)));
        Drain(() => true, capture);
        Assert.That(results.Count, Is.EqualTo(2), "A drained receipt must not replay its mutation.");

        // Synthetic identities only. The native Swift helper consumes these
        // actual receiver callbacks to verify its exact-field acceptance gate.
        File.WriteAllText(Path.Combine(Path.GetTempPath(), "maaso-sidecar-arbiter-results.json"),
            new JArray(results.Select(value => value.DeepClone())).ToString(Formatting.Indented));
    }

    [Test]
    public void StaleTicketReturnsFailureWithoutDisconnectingOrBlockingReset()
    {
        JObject command = MouthCommand(1);
        Enqueue("avatarArbiterCommand", command);
        Enqueue("avatarArbiterCommand", command);
        JObject reset = ResetCommand();
        Enqueue("avatarArbiterReset", reset);
        Drain(() => true, (_, __) => Assert.Fail("No portal command was enqueued."));
        Assert.That(results.Count, Is.EqualTo(3));
        AssertReceipt(results[0], command, "avatarArbiterCommand", true, "");
        AssertReceipt(results[1], command, "avatarArbiterCommand", false, "stale_ticket");
        AssertReceipt(results[2], reset, "avatarArbiterReset", true, "");
        Assert.That(face.GetBlendShapeWeight(0), Is.LessThan(1));
    }

    [Test]
    public void UnknownMethodStillFailsBeforeQueueing()
    {
        Assert.Throws<InvalidOperationException>(() => Enqueue("avatarArbiterUnknown", MouthCommand(1)));
        Drain(() => true, (_, __) => Assert.Fail("No portal command was enqueued."));
        Assert.That(results, Is.Empty);
        Assert.That(face.GetBlendShapeWeight(0), Is.Zero);
    }

    private void CaptureReceiverResult(string text, string stack, LogType type)
    {
        const string prefix = "[UnityAvatar] command result ";
        if (!text.StartsWith(prefix, StringComparison.Ordinal)) return;
        JObject result = JObject.Parse(text.Substring(prefix.Length));
        if (result.Value<string>("method") is not ("avatarArbiterCommand" or "avatarArbiterReset")) return;
        // This is the same bounded JSON parser used by SendValidatedPayload
        // before the macOS avatarResult callback is serialized onto the socket.
        MethodInfo parse = bridge.GetType().GetMethod("ParseObject", BindingFlags.NonPublic | BindingFlags.Static);
        JObject outgoing = (JObject)parse.Invoke(null, new object[] { result.ToString(Formatting.None), 32 * 1024 });
        results.Add(outgoing);
        if (outgoing.Value<string>("method") == "avatarArbiterCommand" && outgoing.Value<bool>("ok"))
            Assert.That(face.GetBlendShapeWeight(0), Is.GreaterThan(65), "Success must be emitted after actual mouth mutation.");
    }

    private static void AssertReceipt(JObject actual, JObject sent, string method, bool ok, string code)
    {
        JObject expected = (JObject)sent.DeepClone();
        expected.Remove("payloadJson");
        expected["method"] = method;
        expected["ok"] = ok;
        expected["code"] = code;
        Assert.That(JToken.DeepEquals(actual, expected), Is.True,
            "Receiver/sidecar must preserve every fence, digest and receipt field: " + actual);
    }

    private void Enqueue(string method, JObject payload) => Invoke(bridge, "EnqueueInboundCommand", "avatarCommand",
        new JObject { ["method"] = method, ["json"] = payload.ToString(Formatting.None) });

    private void Drain(Func<bool> ready, Action<string, int> portal) => Invoke(bridge, "DrainInboundCommands", ready, portal,
        (Action<string>)(payload => receiver.GetType().GetMethod("OnFlutterCommand").Invoke(receiver, new object[] { payload })));

    private static void Invoke(Component target, string name, params object[] arguments)
    {
        try { target.GetType().GetMethod(name, PrivateInstance).Invoke(target, arguments); }
        catch (TargetInvocationException error) when (error.InnerException != null)
        { ExceptionDispatchInfo.Capture(error.InnerException).Throw(); throw; }
    }

    private static JObject MouthCommand(long ticket)
    {
        const string payload = "{\"channel\":\"mouth\",\"value\":0.72}";
        return new JObject
        {
            ["protocolVersion"] = 1, ["requestId"] = "request_1", ["ticket"] = ticket,
            ["rendererId"] = "renderer-instance-1", ["ownerToken"] = new string('A', 43),
            ["commitToken"] = new string('C', 43), ["accountGeneration"] = 7, ["rendererGeneration"] = 1,
            ["channel"] = "mouth", ["fingerprint"] = "0123456789abcdef", ["payloadJson"] = payload,
            ["payloadSha256"] = Digest(payload), ["deadlineEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000,
            ["clearsChannel"] = false,
        };
    }

    private static JObject ResetCommand()
    {
        const string payload = "{\"reset\":true}";
        return new JObject
        {
            ["protocolVersion"] = 1, ["requestId"] = "reset_1", ["requirementId"] = 1,
            ["rendererId"] = "renderer-instance-1", ["targetOwnerToken"] = new string('B', 43),
            ["commitToken"] = new string('D', 43), ["retiredAccountGeneration"] = 7, ["retiredRendererGeneration"] = 1,
            ["targetAccountGeneration"] = 8, ["targetRendererGeneration"] = 2, ["payloadJson"] = payload,
            ["payloadSha256"] = Digest(payload), ["deadlineEpochMs"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 4000,
        };
    }

    private static string Digest(string payload)
    {
        using SHA256 hash = SHA256.Create();
        return string.Concat(hash.ComputeHash(Encoding.UTF8.GetBytes(payload)).Select(value => value.ToString("x2")));
    }
}
