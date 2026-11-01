using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class TemporaryAvatarTurnTests
{
    [TestCase("turn_left", -0.45f)]
    [TestCase("turn_right", 0.45f)]
    [TestCase("turn_back", Mathf.PI)]
    [TestCase("look_back", Mathf.PI)]
    public void SemanticTurnInterpolatesAndReturnsWithoutAnimator(string motion, float yaw)
    {
        using var fixture = new Fixture();
        Quaternion home = fixture.Root.localRotation;
        Vector3 position = fixture.Root.localPosition;
        Vector3 scale = fixture.Root.localScale;
        fixture.Motion(motion, 1600);

        AssertRotation(fixture.Root, home);
        fixture.ProgressTransition(0.5f);
        float angle = Quaternion.Angle(home, fixture.Root.localRotation);
        Assert.That(angle, Is.GreaterThan(1f));
        Assert.That(angle, Is.LessThan(Mathf.Abs(yaw) * Mathf.Rad2Deg - 1f));
        fixture.CompleteTransition();
        Quaternion turned = home * Quaternion.Euler(0f, yaw * Mathf.Rad2Deg, 0f);
        AssertRotation(fixture.Root, turned);
        fixture.Invoke("UpdateIdlePose");
        AssertRotation(fixture.Root, turned, "The turn must remain during its hold.");

        // Even an active idle clip cannot suppress the rotation return.
        fixture.Set("designedIdleActive", true);
        fixture.Set("nextIdleStateAt", Time.realtimeSinceStartup + 100f);
        fixture.ExpireHold();
        AssertRotation(fixture.Root, turned, "The return must also interpolate.");
        fixture.ProgressTransition(0.5f);
        Assert.That(Quaternion.Angle(home, fixture.Root.localRotation), Is.InRange(1f, angle + 1f));
        fixture.CompleteTransition();
        fixture.Invoke("UpdateIdlePose");
        AssertRotation(fixture.Root, home);
        Assert.That(fixture.Root.localPosition, Is.EqualTo(position));
        Assert.That(fixture.Root.localScale, Is.EqualTo(scale));
    }

    [TestCase(2400, 2.4f)]
    [TestCase(9000, 5f)]
    [TestCase(1, 0.2f)]
    public void SemanticTurnUsesBoundedRequestedHold(int durationMs, float seconds)
    {
        using var fixture = new Fixture();
        float before = Time.realtimeSinceStartup;
        fixture.Motion("turn_back", durationMs);
        float after = Time.realtimeSinceStartup;
        Assert.That(fixture.Get<float>("actionPoseHoldUntil"),
            Is.InRange(before + seconds - 0.01f, after + seconds + 0.01f));
    }

    [Test]
    public void OmittedDurationUsesExistingIdleActionHold()
    {
        using var fixture = new Fixture();
        fixture.Set("idleActionHoldSeconds", 2f);
        float before = Time.realtimeSinceStartup;
        fixture.Command("playMotion", "{\"type\":\"look_back\"}");
        Assert.That(fixture.Get<float>("actionPoseHoldUntil"),
            Is.InRange(before + 1.99f, Time.realtimeSinceStartup + 2.01f));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ExplicitPoseCancelsOutwardOrReturningTurnAndRemainsPersistent(bool returning)
    {
        using var fixture = new Fixture();
        fixture.StartTurnPhase(returning);
        fixture.Command("setBodyPose", "{\"yaw\":0.6,\"x\":0.3,\"durationMs\":200}");
        fixture.CompleteTransition();
        Quaternion expected = fixture.Home * Quaternion.Euler(0f, 0.6f * Mathf.Rad2Deg, 0f);
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(fixture.Root, expected);
        Assert.That(fixture.Root.localPosition.x, Is.EqualTo(0.55f).Within(0.001f));
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ResetCancelsOutwardOrReturningTurn(bool returning)
    {
        using var fixture = new Fixture();
        fixture.StartTurnPhase(returning);
        fixture.Motion("reset", 100);
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(fixture.Root, fixture.Home);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ProductionBodyClearCancelsTemporaryTurn(bool returning)
    {
        using var fixture = new Fixture();
        fixture.StartTurnPhase(returning);
        fixture.Invoke("ResetAvatarArbiterBodyGesture");
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(fixture.Root, fixture.Home);
    }

    [Test]
    public void NewSemanticTurnSupersedesOldReturn()
    {
        using var fixture = new Fixture();
        fixture.StartTurnPhase(returning: true);
        fixture.Motion("turn_right", 1600);
        fixture.CompleteTransition();
        fixture.Invoke("UpdateIdlePose");
        AssertRotation(fixture.Root, fixture.Home * Quaternion.Euler(0f, 0.45f * Mathf.Rad2Deg, 0f));
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(fixture.Root, fixture.Home);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void RebaseCancelsTurnBeforeNewHomeRotation(bool returning)
    {
        using var fixture = new Fixture();
        fixture.StartTurnPhase(returning);
        Quaternion newHome = Quaternion.Euler(0f, 35f, 0f);
        fixture.Root.localRotation = newHome;
        fixture.Invoke("RebaseActiveAvatarRootPose");
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(fixture.Root, newHome);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void ModelBindCancelsTurnWithoutWritingNewRoot(bool returning)
    {
        using var fixture = new Fixture();
        fixture.StartTurnPhase(returning);
        Transform replacement = fixture.CreateChild("Replacement");
        replacement.localRotation = Quaternion.Euler(0f, 70f, 0f);
        Quaternion expected = replacement.localRotation;
        fixture.Invoke("BindAvatarRoot", replacement);
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(replacement, expected);
    }

    [TestCase(false)]
    [TestCase(true)]
    public void WorldLeaseCancelsTurnBeforeChangingParent(bool returning)
    {
        using var fixture = new Fixture();
        fixture.StartTurnPhase(returning);
        Transform world = fixture.CreateChild("WorldEntity");
        Assert.That(fixture.Invoke("TryLeaseActiveAvatarForWorld", world), Is.EqualTo(true));
        Quaternion leased = fixture.Root.localRotation;
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(fixture.Root, leased);
        fixture.Motion("turn_back", 200);
        fixture.ExpireHold();
        fixture.CompleteTransition();
        AssertRotation(fixture.Root, leased, "World movement keeps ownership of the leased root.");
    }

    [Test]
    public void OrdinaryIdleDoesNotResetAnExplicitPersistentPose()
    {
        using var fixture = new Fixture();
        fixture.Command("setBodyPose", "{\"yaw\":1.2,\"durationMs\":0}");
        Quaternion expected = fixture.Root.localRotation;
        fixture.ExpireHold();
        fixture.Invoke("UpdateIdlePose");
        AssertRotation(fixture.Root, expected);
    }

    private static void AssertRotation(Transform root, Quaternion expected, string message = null)
    {
        Assert.That(Quaternion.Angle(root.localRotation, expected), Is.LessThan(0.1f), message);
    }

    [Serializable]
    private sealed class Envelope
    {
        public string method;
        public string json;
    }

    private sealed class Fixture : IDisposable
    {
        private readonly GameObject host;
        private readonly Component receiver;
        public Transform Root { get; }
        public Quaternion Home { get; }

        public Fixture()
        {
            host = new GameObject("TemporaryTurnFixture");
            host.SetActive(false);
            Root = CreateChild("AvatarRoot");
            Root.localPosition = new Vector3(0.25f, 0f, 0.1f);
            Root.localRotation = Quaternion.Euler(0f, 180f, 0f);
            Root.localScale = Vector3.one * 0.9f;
            Home = Root.localRotation;
            Type type = Type.GetType("Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp");
            Assert.That(type, Is.Not.Null);
            receiver = host.AddComponent(type);
            Set("avatarRoot", Root);
            Invoke("BindAvatarRoot", Root);
        }

        public Transform CreateChild(string name)
        {
            var child = new GameObject(name);
            child.transform.SetParent(host.transform, false);
            return child.transform;
        }

        public void Motion(string motion, int durationMs) => Command("playMotion",
            "{\"type\":\"" + motion + "\",\"options\":{\"durationMs\":" + durationMs + "}}");

        public void Command(string method, string json) => Invoke("OnFlutterCommand",
            JsonUtility.ToJson(new Envelope { method = method, json = json }));

        public void StartTurnPhase(bool returning)
        {
            Motion("turn_back", 1600);
            if (!returning) return;
            CompleteTransition();
            ExpireHold();
        }

        public void ProgressTransition(float fraction)
        {
            float duration = Get<float>("bodyPoseTransitionDurationSeconds");
            Set("bodyPoseTransitionStartedAt", Time.realtimeSinceStartup - duration * fraction);
            Invoke("UpdateBodyPoseTransition");
        }

        public void CompleteTransition() => ProgressTransition(2f);

        public void ExpireHold()
        {
            Set("actionPoseHoldUntil", -1f);
            Invoke("UpdateIdlePose");
        }

        public T Get<T>(string name) => (T)Field(name).GetValue(receiver);
        public void Set(string name, object value) => Field(name).SetValue(receiver, value);

        private FieldInfo Field(string name)
        {
            var field = receiver.GetType().GetField(name, BindingFlags.NonPublic | BindingFlags.Instance);
            Assert.That(field, Is.Not.Null, name);
            return field;
        }

        public object Invoke(string name, params object[] args)
        {
            var method = receiver.GetType().GetMethod(name,
                BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Instance);
            Assert.That(method, Is.Not.Null, name);
            return method.Invoke(receiver, args);
        }

        public void Dispose() => UnityEngine.Object.DestroyImmediate(host);
    }
}
