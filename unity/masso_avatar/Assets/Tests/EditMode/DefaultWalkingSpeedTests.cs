using System;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class DefaultWalkingSpeedTests
{
    private static Type A(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);
    private static Type W(string name) => Type.GetType("Maaso.World." + name + ", Assembly-CSharp", true);
    private static object Call(object value, string method, params object[] args) => value.GetType()
        .GetMethod(method, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).Invoke(value, args);

    [Test]
    public void SharedDefaultWalkingSpeedIsExactlyFifteenPercentFaster()
    {
        Assert.That((float)W("WorldLocomotionPresentation").GetField("WalkingSpeedMetersPerSecond").GetRawConstantValue(),
            Is.EqualTo(1.84f).Within(.000001f));
    }

    [Test]
    public void DirectStandardWalkAndStationaryPresenceRaiseAuthoredGaitOnly()
    {
        using var f = new Fixture();
        float Sample(string state)
        {
            f.Animator.Play(state, 0, 0f); f.Animator.Update(0f); f.Animator.Update(.25f);
            return f.Animator.GetCurrentAnimatorStateInfo(0).normalizedTime;
        }
        f.Animator.SetFloat("WorldWalkSpeed", 1f);
        float original = Sample("standard_walk"), idle = Sample("idle_shrug");
        Assert.That(Call(f.Receiver, "TryPlayAnimatorState", "standard_walk"), Is.EqualTo(true));
        Assert.That(Sample("standard_walk") / original, Is.EqualTo(1.15f).Within(.0005f));
        Assert.That(Sample("idle_shrug"), Is.EqualTo(idle).Within(.0005f));
        Assert.That(f.Animator.speed, Is.EqualTo(1f));
        f.Animator.SetFloat("WorldWalkSpeed", 1f);
        Assert.That(Call(f.Receiver, "TryStartPresenceWalk"), Is.EqualTo(true));
        Assert.That(Sample("standard_walk") / original, Is.EqualTo(1.15f).Within(.0005f));
        Assert.That(f.Animator.speed, Is.EqualTo(1f));
    }

    [Test]
    public void FurnitureApproachMovesAtBoostedOwnRateAndCalibratesTheWalk()
    {
        using var f = new Fixture();
        GameObject room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        object furniture = Activator.CreateInstance(A("AvatarFurniturePoseController"));
        try
        {
            Component rig = room.GetComponentInChildren(A("AvatarFurnitureRig"));
            bool accepted = (bool)Call(furniture, "BeginWorkSession", new string('d', 64), f.Avatar.transform,
                f.Animator, rig, 0f, (Action<string>)(_ => {}),
                (Action<bool>)(active => Call(f.Receiver, "SetWorldLocomotion", active)));
            Assert.That(accepted, Is.True);
            float travelled = 0f; int movingFrames = 0;
            for (int frame = 1; frame <= 30; frame++)
            {
                Vector3 before = f.Avatar.transform.position;
                Call(furniture, "Advance", frame / 120f, 1f / 120f);
                float moved = Vector3.Distance(before, f.Avatar.transform.position);
                if (moved > .00001f) { travelled += moved; movingFrames++; }
            }
            Assert.That(movingFrames, Is.GreaterThan(10));
            Assert.That(travelled / (movingFrames / 120f), Is.EqualTo(.9775f).Within(.001f));
            float ownRate = f.Animator.GetFloat("WorldWalkSpeed");
            W("WorldLocomotionPresentation").GetMethod("ApplyWalkingAnimationSpeed")
                .Invoke(null, new object[] { f.Animator, true, .9775f });
            Assert.That(ownRate, Is.EqualTo(f.Animator.GetFloat("WorldWalkSpeed")).Within(.00001f),
                "The callback's navigation speed must be replaced by the furniture approach's actual velocity.");
            Call(furniture, "Reset", false);
            Assert.That(f.Animator.GetFloat("WorldWalkSpeed"), Is.EqualTo(1f));
            Assert.That(f.Animator.speed, Is.EqualTo(1f));
        }
        finally { Call(furniture, "Reset", false); Object.DestroyImmediate(room); }
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Avatar;
        public readonly Animator Animator;
        public readonly Component Receiver;
        private readonly GameObject host;
        public Fixture()
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            Avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            Avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            Animator = Avatar.GetComponentInChildren<Animator>(true);
            Animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            Animator.applyRootMotion = false; Animator.Rebind(); Animator.Update(0f);
            host = new GameObject("Default walk receiver"); Receiver = host.AddComponent(A("UnityAvatarCommandReceiver"));
            Receiver.GetType().GetField("avatarRoot", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(Receiver, Avatar.transform);
            Receiver.GetType().GetField("animator", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(Receiver, Animator);
        }
        public void Dispose()
        {
            Object.DestroyImmediate(host); Object.DestroyImmediate(Avatar);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        }
    }
}
