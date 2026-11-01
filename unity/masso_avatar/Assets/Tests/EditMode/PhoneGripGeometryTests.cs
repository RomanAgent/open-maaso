using System;
using System.Collections.Generic;
using System.Linq;
using System.Linq.Expressions;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.TestTools;
using UniVRM10;

public sealed class PhoneGripGeometryTests
{
    private const float Frame = 1f / 60f;
    private static readonly string[] Fingers = { "Index", "Middle", "Ring", "Little" };

    [Test]
    public void DefaultVrmKeepsWristAndPalmAlignedThroughTakingOutReadingReplyingAndReturning()
    {
        using var f = new Fixture();
        int leftSamples = 0, rightSamples = 0;
        RunSequence(f, (phase, elapsed, now) =>
        {
            if (f.Phone == null || !f.Phone.activeSelf) return;
            // Pickup needs time to reach the prop. Every visible return frame
            // remains subject to the wrist check, including the end of pickup IK.
            if (phase != "reading" || elapsed >= .25f)
            {
                AssertWrist(f, true, phase, now);
                leftSamples++;
            }
            if (phase == "replying" && elapsed >= .5f)
            {
                AssertWrist(f, false, phase, now);
                rightSamples++;
            }
        });
        Assert.That(leftSamples, Is.GreaterThan(30), "The visible holding hand must actually be sampled.");
        Assert.That(rightSamples, Is.GreaterThan(30), "The replying hand must actually take over and be sampled.");
        Assert.That((bool)f.Controller.OwnsHands, Is.False);
        Assert.That(f.Phone.activeSelf, Is.False);
    }

    [Test]
    public void DefaultVrmReplyingDoesNotCrossTheAnatomicalLeftAndRightHands()
    {
        using var f = new Fixture();
        RunSequence(f, (phase, elapsed, now) =>
        {
            if (phase != "replying" || elapsed < .5f) return;
            Vector3 left = f.Bone(HumanBodyBones.LeftHand).position;
            Vector3 right = f.Bone(HumanBodyBones.RightHand).position;
            float separation = Vector3.Dot(right - left, f.Root.right);
            Assert.That(separation, Is.GreaterThan(f.PhoneWidth * .1f),
                $"At {now:F3}s, anatomical hand ordering reversed or both wrists collapsed together: {separation:F4}m.");
        });
    }

    [Test]
    public void ReplyingHandReturnsOnItsOwnSideWhileHoldingHandPutsThePhoneAway()
    {
        using var f = new Fixture();
        int samples = 0;
        RunSequence(f, (phase, elapsed, now) =>
        {
            if (phase != "none") return;
            samples++;
            float side = Vector3.Dot(f.Bone(HumanBodyBones.RightHand).position
                - f.Bone(HumanBodyBones.Hips).position, f.Root.right);
            Assert.That(side, Is.GreaterThanOrEqualTo(0f),
                $"At {now:F3}s the releasing right hand follows the phone across the torso ({side:F4}m).");
        });
        Assert.That(samples, Is.GreaterThan(30));
    }

    [Test]
    public void DefaultVrmKeepsThePhoneNearActualFingerSegmentsDuringItsVisibleGrip()
    {
        using var f = new Fixture();
        int leftSamples = 0, rightSamples = 0;
        RunSequence(f, (phase, elapsed, now) =>
        {
            if (f.Phone == null || !f.Phone.activeSelf) return;
            if ((phase != "reading" || elapsed >= .25f) && (phase != "none" || elapsed <= .5f))
            {
                AssertContact(f, true, phase, now);
                leftSamples++;
            }
            if (phase == "replying" && elapsed >= .5f)
            {
                AssertContact(f, false, phase, now);
                rightSamples++;
            }
        });
        Assert.That(leftSamples, Is.GreaterThan(30), "A permanently hidden phone must not pass the contact test.");
        Assert.That(rightSamples, Is.GreaterThan(30), "The second hand must actually be sampled near the visible phone.");
    }

    [Test]
    public void ZeroWeightPickupAndCompletedReturnPreserveTheExternalUpperBodyPose()
    {
        using var f = new Fixture();
        // Settle the VRM constraints before comparing controller-owned rotations.
        f.Advance(0f);
        var owned = new List<HumanBodyBones>
        {
            HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand,
            HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand,
            HumanBodyBones.Neck, HumanBodyBones.Head,
        };
        owned.AddRange(Enum.GetValues(typeof(HumanBodyBones)).Cast<HumanBodyBones>()
            .Where(bone => Fingers.Concat(new[] { "Thumb" }).Any(finger => bone.ToString().Contains(finger))));
        var before = owned.ToDictionary(bone => bone, bone => f.Bone(bone).localRotation);
        f.Execute("reading", 0f);
        f.Advance(0f);
        foreach (var pair in before)
            Assert.That(Quaternion.Angle(pair.Value, f.Bone(pair.Key).localRotation), Is.LessThan(.15f),
                pair.Key + " changed when pickup had zero weight.");

        f.Advance(1.2f);
        f.Execute("none", 1.4f);
        for (int frame = 1; frame <= 60; frame++) f.Advance(1.4f + frame * Frame);
        Assert.That((bool)f.Controller.OwnsHands, Is.False);
        foreach (var pair in before)
            Assert.That(Quaternion.Angle(pair.Value, f.Bone(pair.Key).localRotation), Is.LessThan(.15f),
                pair.Key + " was not restored after the phone return completed.");
    }

    [Test]
    public void ExistingAnimatedFingerCurlStaysBoundedStableAndReturnsAfterPhoneUse()
    {
        using var f = new Fixture();
        f.ApplyAnimatedFingerCurl();
        Dictionary<HumanBodyBones, Quaternion> animated = f.FingerRotations();
        float startingBend = MaximumFingerBend(f);
        Assert.That(startingBend, Is.GreaterThan(25f), "The fixture must already contain a bent-finger animation pose.");
        Assert.That(startingBend, Is.LessThan(100f), "The animation fixture itself must be within a comfortable finger range.");

        f.Execute("reading", 0f);
        f.Advance(1.2f);
        AssertBoundedFingers(f, "reading over an existing curl");
        AssertStableNonThumbFingers(f, 1.2f);

        f.Execute("replying", 2.3f);
        f.Advance(2.9f);
        AssertBoundedFingers(f, "replying over an existing curl");
        AssertStableNonThumbFingers(f, 2.9f);

        f.Execute("none", 4.1f);
        for (int frame = 1; frame <= 60; frame++) f.Advance(4.1f + frame * Frame);
        Assert.That((bool)f.Controller.OwnsHands, Is.False);
        foreach (var pair in animated)
            Assert.That(Quaternion.Angle(pair.Value, f.Bone(pair.Key).localRotation), Is.LessThan(.5f),
                pair.Key + " did not return to the external animation pose after putting the phone away.");
    }

    [TestCase(.8f, 0f)]
    [TestCase(1f, 0f)]
    [TestCase(1.2f, 73f)]
    public void PhoneFitsTheHoldingPalmInsteadOfGrowingWithTorsoScale(float scale, float yaw)
    {
        using var f = new Fixture();
        f.Root.localScale *= scale;
        f.Root.rotation = Quaternion.AngleAxis(yaw, Vector3.up) * f.Root.rotation;
        float palmWidth = Vector3.Distance(f.Bone(HumanBodyBones.LeftIndexProximal).position,
            f.Bone(HumanBodyBones.LeftLittleProximal).position);
        float palmLength = Vector3.Distance(f.Bone(HumanBodyBones.LeftHand).position,
            f.Bone(HumanBodyBones.LeftMiddleProximal).position);
        f.Execute("reading", 0f);
        f.Advance(1.1f);
        Transform chassis = f.Phone.transform.Find("Rounded metal chassis");
        Vector3 size = chassis.GetComponent<MeshFilter>().sharedMesh.bounds.size;
        float height = chassis.TransformVector(Vector3.up * size.y).magnitude;
        Assert.That(f.PhoneWidth / palmWidth, Is.InRange(1.0f, 1.2f),
            "Phone width should be close to the holding palm, allowing for soft tissue beyond the knuckle span.");
        Assert.That(height / palmLength, Is.InRange(1.4f, 1.7f),
            "The phone cannot grow into a tablet on a model with longer metacarpals.");
    }

    [TestCase("reading")]
    [TestCase("replying")]
    [TestCase("early")]
    public void EntireReturnKeepsAnatomicalJointsContinuousIncludingHiddenReleaseFrames(string from)
    {
        using var f = new Fixture();
        f.Execute("reading", 0f);
        float returnAt = from == "early" ? .3f : 1.2f;
        for (int frame = 0; frame <= Mathf.RoundToInt(returnAt / Frame); frame++) f.Advance(frame * Frame);
        if (from == "replying")
        {
            f.Execute("replying", returnAt);
            for (int frame = 1; frame <= 36; frame++) f.Advance(returnAt + frame * Frame);
            returnAt += .6f;
        }
        HumanBodyBones[] joints = {
            HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand,
            HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand };
        var previous = joints.ToDictionary(bone => bone, bone => f.Bone(bone).localRotation);
        Vector3 root = f.Root.position;
        Quaternion leg = f.Bone(HumanBodyBones.LeftUpperLeg).localRotation;
        f.Execute("none", returnAt);
        int hiddenFrames = 0;
        for (int frame = 0; frame <= 60; frame++)
        {
            float now = returnAt + frame * Frame;
            f.Advance(now);
            if (!f.Phone.activeSelf) hiddenFrames++;
            foreach (HumanBodyBones joint in joints)
            {
                Quaternion current = f.Bone(joint).localRotation;
                Assert.That(Quaternion.Angle(previous[joint], current), Is.LessThan(12f),
                    $"{joint} snapped at return {frame * Frame:F3}s from {from}; include the full release, not only the visible grip.");
                previous[joint] = current;
            }
            AssertWrist(f, true, "complete return", now);
            AssertWrist(f, false, "complete return", now);
            Assert.That(Vector3.Distance(root, f.Root.position), Is.LessThan(.00001f));
            Assert.That(Quaternion.Angle(leg, f.Bone(HumanBodyBones.LeftUpperLeg).localRotation), Is.LessThan(.01f));
        }
        Assert.That(hiddenFrames, Is.GreaterThan(10), "Release after stowing must actually be covered.");
        Assert.That((bool)f.Controller.OwnsHands, Is.False);
    }

    private static void RunSequence(Fixture f, Action<string, float, float> sample)
    {
        foreach (var step in new[]
        {
            (phase: "reading", start: 0f, frames: 78),
            (phase: "replying", start: 1.3f, frames: 78),
            (phase: "none", start: 2.6f, frames: 60),
        })
        {
            f.Execute(step.phase, step.start);
            for (int frame = 1; frame <= step.frames; frame++)
            {
                float elapsed = frame * Frame;
                float now = step.start + elapsed;
                f.Advance(now);
                sample(step.phase, elapsed, now);
            }
        }
    }

    private static void AssertWrist(Fixture f, bool left, string phase, float now)
    {
        Transform elbow = f.Bone(left ? HumanBodyBones.LeftLowerArm : HumanBodyBones.RightLowerArm);
        Transform wrist = f.Bone(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
        Transform knuckle = f.Bone(left ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal);
        Vector3 forearm = wrist.position - elbow.position;
        Vector3 palm = knuckle.position - wrist.position;
        Assert.That(forearm.sqrMagnitude, Is.GreaterThan(.0001f));
        Assert.That(palm.sqrMagnitude, Is.GreaterThan(.00001f));
        float bend = Vector3.Angle(forearm, palm);
        Assert.That(bend, Is.LessThanOrEqualTo(60f),
            $"{(left ? "Left" : "Right")} wrist folds {bend:F1} degrees during {phase} at {now:F3}s.");
    }

    private static void AssertContact(Fixture f, bool left, string phase, float now)
    {
        float distance = float.PositiveInfinity;
        foreach (string finger in Fingers.Concat(new[] { "Thumb" }))
        {
            Transform[] joints = f.Finger(left, finger);
            var points = joints.Select(joint => joint.position).ToList();
            Transform tip = joints[2];
            if (tip.childCount > 0) points.Add(tip.GetChild(0).position);
            for (int joint = 0; joint < points.Count - 1; joint++)
                for (int segment = 0; segment <= 4; segment++)
                    distance = Mathf.Min(distance, f.DistanceFromPhone(Vector3.Lerp(points[joint], points[joint + 1], segment / 4f)));
        }
        // This is a coarse contact envelope based on the real prop's dimensions,
        // not a comparison with a private IK target or a hard-coded grip offset.
        Assert.That(distance, Is.LessThan(f.PhoneWidth * .5f),
            $"{(left ? "Holding" : "Replying")} hand floats {distance:F4}m away from the phone during {phase} at {now:F3}s.");
    }

    private static float MaximumFingerBend(Fixture f)
    {
        float maximum = 0f;
        foreach (bool left in new[] { true, false })
            foreach (string finger in Fingers)
            {
                Transform[] joints = f.Finger(left, finger);
                maximum = Mathf.Max(maximum, Vector3.Angle(joints[1].position - joints[0].position,
                    joints[2].position - joints[1].position));
            }
        return maximum;
    }

    private static void AssertBoundedFingers(Fixture f, string context)
    {
        float bend = MaximumFingerBend(f);
        Assert.That(bend, Is.LessThanOrEqualTo(100f),
            $"The {context} bends a proximal finger joint {bend:F1} degrees; grip must not add another full curl to an already bent animation.");
    }

    private static void AssertStableNonThumbFingers(Fixture f, float start)
    {
        Dictionary<HumanBodyBones, Quaternion> first = f.FingerRotations();
        for (int frame = 1; frame <= 60; frame++)
        {
            f.Advance(start + frame * Frame);
            foreach (var pair in first)
                Assert.That(Quaternion.Angle(pair.Value, f.Bone(pair.Key).localRotation), Is.LessThan(.5f),
                    pair.Key + " accumulates phone overlay rotation over repeated frames.");
        }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Transform Root;
        public readonly Animator Animator;
        public readonly dynamic Controller;
        private readonly Vrm10Instance vrm;
        private int sequence;
        public GameObject Phone => (GameObject)Controller.Phone;
        private Transform Chassis => Phone.transform.Find("Rounded metal chassis");
        private Bounds ChassisBounds => Chassis.GetComponent<MeshFilter>().sharedMesh.bounds;
        public float PhoneWidth => Chassis.TransformVector(Vector3.right * ChassisBounds.size.x).magnitude;

        public Fixture()
        {
            EditorSceneManager.OpenScene("Assets/MaasoAvatar/Scenes/Companion.unity", OpenSceneMode.Single);
            Root = GameObject.Find("MaasoDefaultAvatar").transform;
            Animator = Root.GetComponentInChildren<Animator>();
            vrm = Root.GetComponentInChildren<Vrm10Instance>();
            Assert.That(vrm, Is.Not.Null, "Use the shipped default VRM, not a synthetic bone chain.");
            // Unity logs UniVRM's EditMode material access once per material slot.
            int materialAccessCount = vrm.GetComponentsInChildren<Renderer>()
                .Where(renderer => renderer is SkinnedMeshRenderer || renderer is MeshRenderer)
                .Sum(renderer => renderer.sharedMaterials.Length);
            for (int index = 0; index < materialAccessCount; index++)
                LogAssert.Expect(LogType.Error, new Regex("Instantiating material due to calling renderer\\.material"));
            vrm.Runtime.Process();
            Animator.Rebind();
            Animator.Update(0f);
            Type result = TypeOf("AvatarPhoneResult");
            Delegate callback = Expression.Lambda(typeof(Action<>).MakeGenericType(result),
                Expression.Empty(), Expression.Parameter(result, "result")).Compile();
            Controller = Activator.CreateInstance(TypeOf("AvatarPhoneInteractionController"), callback);
        }

        public Transform Bone(HumanBodyBones bone)
        {
            Transform value = Animator.GetBoneTransform(bone);
            Assert.That(value, Is.Not.Null, bone + " is required by the default VRM geometry fixture.");
            return value;
        }

        public Transform[] Finger(bool left, string finger) => new[] { "Proximal", "Intermediate", "Distal" }
            .Select(joint => Bone((HumanBodyBones)Enum.Parse(typeof(HumanBodyBones), (left ? "Left" : "Right") + finger + joint))).ToArray();

        public Dictionary<HumanBodyBones, Quaternion> FingerRotations() =>
            Enum.GetValues(typeof(HumanBodyBones)).Cast<HumanBodyBones>()
                .Where(bone => Fingers.Any(finger => bone.ToString().Contains(finger)))
                .ToDictionary(bone => bone, bone => Bone(bone).localRotation);

        public void ApplyAnimatedFingerCurl()
        {
            using var handler = new HumanPoseHandler(Animator.avatar, Animator.transform);
            var pose = new HumanPose();
            handler.GetHumanPose(ref pose);
            int changed = 0;
            for (int muscle = 0; muscle < HumanTrait.MuscleName.Length; muscle++)
            {
                string name = HumanTrait.MuscleName[muscle];
                if (!name.Contains("Stretched") || !Fingers.Any(finger => name.Contains(finger))) continue;
                pose.muscles[muscle] = -.45f;
                changed++;
            }
            Assert.That(changed, Is.GreaterThanOrEqualTo(16), "The actual Humanoid must expose both hands' finger muscles.");
            handler.SetHumanPose(ref pose);
            vrm.Runtime.Process();
        }

        public void Execute(string phase, float now)
        {
            dynamic command = Activator.CreateInstance(TypeOf("AvatarPhoneCommand"));
            command.requestId = "geometry-" + ++sequence;
            command.interactionId = "geometry-conversation";
            command.phase = phase;
            command.sequence = (long)sequence;
            command.expiresAtMs = 1000L + (long)(now * 1000f) + 5000L;
            Controller.Execute(command, Root, now, 1000L + (long)(now * 1000f));
        }

        public void Advance(float now)
        {
            Controller.Advance(now, 1000L + (long)(now * 1000f));
            // Include the default VRM constraints in the measured result, as in
            // the production late-update/rendering path.
            vrm.Runtime.Process();
        }

        public float DistanceFromPhone(Vector3 worldPoint)
        {
            Vector3 nearest = ChassisBounds.ClosestPoint(Chassis.InverseTransformPoint(worldPoint));
            return Vector3.Distance(worldPoint, Chassis.TransformPoint(nearest));
        }

        public void Dispose()
        {
            Controller.Reset("geometry_test_complete");
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }

        private static Type TypeOf(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    }
}
