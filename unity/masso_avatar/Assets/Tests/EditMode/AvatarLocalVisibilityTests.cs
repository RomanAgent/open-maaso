using System;
using System.Collections.Generic;
using System.Linq.Expressions;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarLocalVisibilityTests
{
    private static Type TypeOf(string name) => Type.GetType("Maaso.Avatar." + name + ", Assembly-CSharp", true);

    [Test]
    public void DefaultHiddenOnlyMasksLocalModelAndRestoresAuthoredFlags()
    {
        using var f = new Fixture();
        Renderer alreadyDisabled = f.Part("Hidden accessory"); alreadyDisabled.enabled = false;
        f.Mask.Apply(f.Root, false);
        Assert.That(f.Body.enabled, Is.False); Assert.That(f.Other.enabled, Is.True);
        Assert.That(f.Body.forceRenderingOff, Is.False);
        Renderer newPart = f.Part("Replacement hair"); f.Mask.Apply(f.Root, false);
        Assert.That(newPart.enabled, Is.False);
        f.Mask.SetVisible(true); f.Mask.Apply(f.Root, false);
        Assert.That(f.Body.enabled, Is.True); Assert.That(newPart.enabled, Is.True);
        Assert.That(alreadyDisabled.enabled, Is.False);
    }

    [Test]
    public void OwnershipTrueNeverOverridesPresenceHiddenFlag()
    {
        using var f = new Fixture();
        f.Mask.Apply(f.Root, false); f.Body.forceRenderingOff = true;
        f.Mask.SetVisible(true); f.Mask.Apply(f.Root, true);
        Assert.That(f.Body.enabled, Is.True); Assert.That(f.Body.forceRenderingOff, Is.True);
        f.Body.forceRenderingOff = false;
        f.Mask.Apply(f.Root, false);
        Assert.That(f.Body.enabled && !f.Body.forceRenderingOff, Is.True);
    }

    [Test]
    public void HiddenTargetPreparesThenOwnerEntersWithoutPollutedPresenceSnapshot()
    {
        using var f = new Fixture();
        f.Mask.Apply(f.Root, false);
        var results = new List<object>();
        var value = Expression.Parameter(TypeOf("AvatarPresenceResult"));
        var callback = Expression.Lambda(typeof(Action<>).MakeGenericType(value.Type),
            Expression.Call(Expression.Constant(results), typeof(List<object>).GetMethod("Add"), Expression.Convert(value, typeof(object))), value).Compile();
        dynamic presence = Activator.CreateInstance(TypeOf("AvatarPresenceTransitionController"), callback);
        dynamic view = f.Camera.gameObject.AddComponent(TypeOf("FrontFullBodyCamera"));
        view.TargetRoot = f.Root;
        dynamic command = Activator.CreateInstance(TypeOf("AvatarPresenceCommand"));
        command.requestId = "prepare"; command.transitionId = "handoff"; command.phase = "prepare";
        command.edge = "right"; command.durationMs = 1000; command.sequence = 1L; command.expiresAtMs = 10000L;
        presence.Execute(command, f.Root, view, new Func<bool>(() => true), new Action(() => {}), 0f, 1000L);
        Assert.That((bool)presence.IsHidden, Is.True);
        f.Mask.SetVisible(true); f.Mask.Apply(f.Root, true);
        Assert.That(f.Body.forceRenderingOff, Is.True, "Adopting the lease must not reveal before entry.");
        command.requestId = "enter"; command.phase = "enter"; command.sequence = 2L;
        presence.Execute(command, f.Root, view, new Func<bool>(() => true), new Action(() => {}), 0f, 1000L);
        presence.Advance(1.1f, 2100L); f.Mask.Apply(f.Root, false);
        Assert.That(f.Body.enabled, Is.True); Assert.That(f.Body.forceRenderingOff, Is.False);
        Assert.That((bool)presence.IsHidden, Is.False); Assert.That(results.Count, Is.EqualTo(2));
        presence.CancelForReset("test_complete");
    }


    [Test]
    public void ModelReplacementAndWorldReparentRemainHiddenUntilOwnerReturns()
    {
        using var f = new Fixture();
        f.Mask.Apply(f.Root, false);
        f.Root.SetParent(f.Other.transform, true); f.Mask.Apply(f.Root, false);
        Assert.That(f.Body.enabled, Is.False); Assert.That(f.Other.enabled, Is.True);
        var replacement = new GameObject("Replacement").transform;
        Renderer model = GameObject.CreatePrimitive(PrimitiveType.Sphere).GetComponent<Renderer>();
        model.transform.SetParent(replacement, false);
        f.Mask.Apply(replacement, false); Assert.That(model.enabled, Is.False);
        f.Mask.SetVisible(true); f.Mask.Apply(replacement, false);
        Assert.That(model.enabled, Is.True); Object.DestroyImmediate(replacement.gameObject);
    }

    private sealed class Fixture : IDisposable
    {
        public readonly Transform Root = new GameObject("Local model").transform;
        public readonly Renderer Body, Other;
        public readonly Camera Camera;
        public readonly dynamic Mask = Activator.CreateInstance(TypeOf("AvatarLocalVisibilityMask"));
        public Fixture()
        {
            Body = Part("Body"); Body.transform.localPosition = Vector3.up; Body.transform.localScale = new Vector3(.6f, 1.8f, .4f);
            Other = GameObject.CreatePrimitive(PrimitiveType.Cube).GetComponent<Renderer>(); Other.name = "Another agent";
            Camera = new GameObject("Camera").AddComponent<Camera>(); Camera.transform.position = new Vector3(0, 1, -5);
            Camera.transform.rotation = Quaternion.identity;
        }
        public Renderer Part(string name)
        {
            GameObject item = GameObject.CreatePrimitive(PrimitiveType.Cube); item.name = name; item.transform.SetParent(Root, false);
            return item.GetComponent<Renderer>();
        }
        public void Dispose()
        {
            Object.DestroyImmediate(Camera.gameObject); Object.DestroyImmediate(Root.gameObject); Object.DestroyImmediate(Other.gameObject);
        }
    }
}
