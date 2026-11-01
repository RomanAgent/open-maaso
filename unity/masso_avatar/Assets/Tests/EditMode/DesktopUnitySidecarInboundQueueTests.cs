using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class DesktopUnitySidecarInboundQueueTests
{
    private GameObject host;
    private Component bridge;
    private MethodInfo enqueue;
    private MethodInfo drain;

    [SetUp]
    public void SetUp()
    {
        Type type = Type.GetType("Maaso.Avatar.DesktopUnitySidecarBridge, Assembly-CSharp", true);
        host = new GameObject("Sidecar inbound queue test");
        bridge = host.AddComponent(type);
        enqueue = type.GetMethod("EnqueueInboundCommand", BindingFlags.Instance | BindingFlags.NonPublic);
        drain = type.GetMethod("DrainInboundCommands", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.That(enqueue, Is.Not.Null);
        Assert.That(drain, Is.Not.Null);
    }

    [TearDown]
    public void TearDown() => Object.DestroyImmediate(host);

    [Test]
    public void ExitCleanupCommandsPrecedeAvatarCaptureInTheSameDrain()
    {
        Avatar("leaveWorld", "{\"instanceId\":\"room\"}");
        Avatar("playMotion", "{\"motion\":\"reset\"}");
        Avatar("setFraming", "{\"mode\":\"hero_full_body\"}");
        Portal("release", 7);
        Portal("acquire", 8);

        var observed = new List<string>();
        bool worldLeaseActive = true;
        Drain(() => true,
            (payload, generation) =>
            {
                string method = JObject.Parse(payload).Value<string>("method");
                if (method == "acquire")
                {
                    Assert.That(worldLeaseActive, Is.False,
                        "Capture must not overtake the queued cleanup after a camera-event timeout.");
                    Assert.That(generation, Is.EqualTo(8));
                }
                observed.Add(method);
            },
            payload =>
            {
                string method = JObject.Parse(payload).Value<string>("method");
                if (method == "leaveWorld") worldLeaseActive = false;
                observed.Add(method);
            });
        Assert.That(observed, Is.EqualTo(new[]
            { "leaveWorld", "playMotion", "setFraming", "release", "acquire" }));
    }

    [Test]
    public void EnterWorldReleasesCaptureBeforeLeasingAvatar()
    {
        Portal("release", 11);
        Avatar("joinWorld", "{\"instanceId\":\"room\"}");
        bool captureActive = true;
        var observed = new List<string>();
        Drain(() => true,
            (payload, _) => { captureActive = false; observed.Add("release"); },
            payload =>
            {
                Assert.That(captureActive, Is.False, "Giving avatar commands blanket priority also breaks ordering.");
                observed.Add(JObject.Parse(payload).Value<string>("method"));
            });
        Assert.That(observed, Is.EqualTo(new[] { "release", "joinWorld" }));
    }

    [Test]
    public void MissingAvatarReceiverRetainsHeadAndBlocksLaterPortalCommands()
    {
        Portal("release", 3);
        Avatar("leaveWorld");
        Portal("acquire", 4);
        var observed = new List<string>();
        Action<string, int> portal = (payload, _) => observed.Add(JObject.Parse(payload).Value<string>("method"));
        Action<string> avatar = payload => observed.Add(JObject.Parse(payload).Value<string>("method"));
        Drain(() => false, portal, avatar);
        Assert.That(observed, Is.EqualTo(new[] { "release" }));
        Drain(() => false, portal, avatar);
        Assert.That(observed, Is.EqualTo(new[] { "release" }), "No retry, drop or overtaking while blocked.");
        Drain(() => true, portal, avatar);
        Assert.That(observed, Is.EqualTo(new[] { "release", "leaveWorld", "acquire" }));
        Drain(() => true, portal, avatar);
        Assert.That(observed.Count, Is.EqualTo(3), "Drained side effects run exactly once.");
    }

    [TestCase(false)]
    [TestCase(true)]
    public void DispatchFailurePropagatesWithoutRequeueOrExecutingLaterCommand(bool portalFailure)
    {
        if (portalFailure) Portal("acquire", 1);
        else Avatar("leaveWorld");
        Portal("release", 2);
        var expected = new InvalidOperationException("existing dispatch failure");
        int attempts = 0;
        Action<string, int> portal = (_, __) => { attempts++; throw expected; };
        Action<string> avatar = _ => { attempts++; throw expected; };
        Assert.That(Assert.Throws<InvalidOperationException>(() => Drain(() => true, portal, avatar)),
            Is.SameAs(expected));
        Assert.That(attempts, Is.EqualTo(1));
        var remaining = new List<string>();
        Drain(() => true,
            (payload, _) => remaining.Add(JObject.Parse(payload).Value<string>("method")),
            _ => Assert.Fail("The failed avatar command must not be replayed."));
        Assert.That(remaining, Is.EqualTo(new[] { "release" }));
    }

    [Test]
    public void ExistingStrictPayloadValidationRunsBeforeEnqueue()
    {
        Assert.Throws<InvalidOperationException>(() => Enqueue("command", new JObject
            { ["method"] = "release", ["generation"] = 1, ["unexpected"] = true }));
        Assert.Throws<InvalidOperationException>(() => Avatar("unsupportedMethod"));
        Assert.Throws<Newtonsoft.Json.JsonReaderException>(() => Avatar("leaveWorld", "[1,2,3]"));
        Assert.Throws<InvalidOperationException>(() => Enqueue("other", new JObject()));
        int dispatched = 0;
        Drain(() => true, (_, __) => dispatched++, _ => dispatched++);
        Assert.That(dispatched, Is.Zero);
    }

    [Test]
    public void FiveVowelTimelineReachesTheReceiverUnchangedAndBeforeItsStop()
    {
        const string timeline = "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.5,0.4,0.3,0.6,0.4,0]," +
            "\"cues\":[{\"frame\":0,\"viseme\":\"aa\"},{\"frame\":1,\"viseme\":\"ee\"}," +
            "{\"frame\":2,\"viseme\":\"ih\"},{\"frame\":3,\"viseme\":\"oh\"}," +
            "{\"frame\":4,\"viseme\":\"ou\"},{\"frame\":5,\"viseme\":\"sil\"}],\"frameRate\":30}";
        Avatar("startVisemeTimeline", timeline);
        Avatar("stopLipSync");
        var observed = new List<string>();
        Drain(() => false, (_, __) => Assert.Fail("No portal command was enqueued."),
            _ => Assert.Fail("The timeline must wait for the real avatar receiver."));
        Drain(() => true, (_, __) => Assert.Fail("No portal command was enqueued."), payload =>
        {
            JObject command = JObject.Parse(payload);
            string method = command.Value<string>("method");
            observed.Add(method);
            if (method == "startVisemeTimeline")
                Assert.That(command.Value<string>("json"), Is.EqualTo(timeline),
                    "The sidecar must retain the vowel cues, format and energy envelope without an Aa fallback.");
        });
        Assert.That(observed, Is.EqualTo(new[] { "startVisemeTimeline", "stopLipSync" }));
    }

    [Test]
    public void WorldCaptureViewportAndAvatarPayloadArePreserved()
    {
        Enqueue("command", new JObject
        {
            ["method"] = "acquire", ["generation"] = 19, ["profile"] = "compactHigh", ["targetFps"] = 30,
            ["includeWorld"] = true, ["viewportWidth"] = 1080, ["viewportHeight"] = 1600,
        });
        const string arguments = "{\"instanceId\":\"room\",\"label\":\"中文\"}";
        Avatar("leaveWorld", arguments);
        int dispatched = 0;
        Drain(() => true,
            (payload, generation) =>
            {
                var value = JObject.Parse(payload);
                Assert.That(generation, Is.EqualTo(19));
                Assert.That(value.Value<bool>("includeWorld"), Is.True);
                Assert.That(value.Value<int>("viewportWidth"), Is.EqualTo(1080));
                Assert.That(value.Value<int>("viewportHeight"), Is.EqualTo(1600));
                Assert.That(value.Value<string>("profile"), Is.EqualTo("compactHigh"));
                Assert.That(value.Value<int>("targetFps"), Is.EqualTo(30));
                dispatched++;
            },
            payload =>
            {
                Assert.That(JObject.Parse(payload).Value<string>("json"), Is.EqualTo(arguments));
                dispatched++;
            });
        Assert.That(dispatched, Is.EqualTo(2));
    }

    [Test]
    public void SocketProducerAndMainThreadConsumerPreserveMixedOrder()
    {
        const int count = 1000;
        var observed = new List<int>();
        using var producerStarted = new ManualResetEventSlim();
        Task producer = Task.Run(() =>
        {
            producerStarted.Set();
            for (int index = 1; index <= count; index++)
            {
                if (index % 2 == 0) Portal("release", index);
                else Avatar("setMouthOpen", "{\"value\":" + index + "}");
            }
        });
        try
        {
            Assert.That(producerStarted.Wait(TimeSpan.FromSeconds(5)), Is.True);
            var timeout = System.Diagnostics.Stopwatch.StartNew();
            do
            {
                Drain(() => true,
                    (_, generation) => observed.Add(generation),
                    payload => observed.Add(JObject.Parse(JObject.Parse(payload).Value<string>("json")).Value<int>("value")));
                if (timeout.Elapsed > TimeSpan.FromSeconds(5)) Assert.Fail("Producer/consumer did not finish.");
                Thread.Yield();
            } while (!producer.IsCompleted || observed.Count < count);
            producer.GetAwaiter().GetResult();
            Assert.That(observed.Count, Is.EqualTo(count));
            for (int index = 0; index < count; index++)
                Assert.That(observed[index], Is.EqualTo(index + 1));
        }
        finally
        {
            Assert.That(producer.Wait(TimeSpan.FromSeconds(5)), Is.True);
        }
    }

    private void Portal(string method, int generation)
    {
        var payload = new JObject { ["method"] = method, ["generation"] = generation };
        if (method == "acquire")
        {
            payload["profile"] = "compactHigh";
            payload["targetFps"] = 30;
        }
        Enqueue("command", payload);
    }

    private void Avatar(string method, string arguments = "{}") =>
        Enqueue("avatarCommand", new JObject { ["method"] = method, ["json"] = arguments });

    private void Enqueue(string type, JObject payload) => Invoke(enqueue, type, payload);

    private void Drain(Func<bool> ready, Action<string, int> portal, Action<string> avatar) =>
        Invoke(drain, ready, portal, avatar);

    private void Invoke(MethodInfo method, params object[] arguments)
    {
        try { method.Invoke(bridge, arguments); }
        catch (TargetInvocationException exception) when (exception.InnerException != null)
        {
            ExceptionDispatchInfo.Capture(exception.InnerException).Throw();
            throw;
        }
    }
}
