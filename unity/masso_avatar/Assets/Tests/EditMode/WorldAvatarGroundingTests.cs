using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class WorldAvatarGroundingTests
{
    private const string GroundingTypeName =
        "Maaso.World.WorldAvatarGrounding, Assembly-CSharp";

    [Test]
    public void GroundVisualSinksRendererPaddingIntoGroundPlane()
    {
        var logicalRoot = new GameObject("GroundingFixture");
        GameObject visual = GameObject.CreatePrimitive(PrimitiveType.Cube);
        visual.transform.SetParent(logicalRoot.transform, false);
        visual.transform.localPosition = new Vector3(0f, -0.75f, 0f);

        try
        {
            object[] arguments = { visual.transform, 0f, 0f };

            bool grounded = (bool)GroundMethod().Invoke(null, arguments);

            float offset = (float)arguments[2];
            Assert.That(grounded, Is.True);
            Assert.That(
                visual.GetComponent<Renderer>().bounds.min.y,
                Is.EqualTo(-0.008f).Within(0.001f));
            Assert.That(float.IsNaN(offset), Is.False);
            Assert.That(float.IsInfinity(offset), Is.False);
            Assert.That(offset, Is.EqualTo(1.242f).Within(0.001f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(logicalRoot);
        }
    }

    [Test]
    public void ParticleOnlyVisualIsRejectedWithoutChangingTransform()
    {
        var visual = new GameObject("ParticleOnlyVisual");
        visual.transform.position = new Vector3(3f, 4f, 5f);
        visual.AddComponent<ParticleSystem>();
        Vector3 originalPosition = visual.transform.position;

        try
        {
            object[] arguments = { visual.transform, 0f, 17f };

            bool grounded = (bool)GroundMethod().Invoke(null, arguments);

            Assert.That(grounded, Is.False);
            Assert.That((float)arguments[2], Is.EqualTo(0f));
            Assert.That(visual.transform.position, Is.EqualTo(originalPosition));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(visual);
        }
    }

    private static MethodInfo GroundMethod()
    {
        Type type = Type.GetType(GroundingTypeName);
        Assert.That(type, Is.Not.Null, "WorldAvatarGrounding should exist.");
        MethodInfo method = type.GetMethod(
            "TryGround",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(method, Is.Not.Null, "TryGround should be public and static.");
        return method;
    }
}
