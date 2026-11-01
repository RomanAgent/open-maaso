using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class WorldAvatarFacingTests
{
    private static Type Subject => Type.GetType(
        "Maaso.World.WorldAvatarFacing, Assembly-CSharp");

    [Test]
    public void StandardHumanoidForwardNeedsNoDisplayCorrection()
    {
        Quaternion correction = ResolveCorrection(
            new Vector3(-1f, 1f, 0f),
            new Vector3(1f, 1f, 0f),
            Vector3.zero,
            new Vector3(0f, 2f, 0f));

        Assert.That(
            Quaternion.Angle(Quaternion.identity, correction),
            Is.LessThan(0.01f));
    }

    [Test]
    public void ReversedHumanoidForwardGetsOneHundredEightyDegreeCorrection()
    {
        Vector3 authoredForward = Vector3.back;
        Quaternion correction = ResolveCorrection(
            new Vector3(1f, 1f, 0f),
            new Vector3(-1f, 1f, 0f),
            Vector3.zero,
            new Vector3(0f, 2f, 0f));

        Assert.That(
            Vector3.Dot(correction * authoredForward, Vector3.forward),
            Is.GreaterThan(0.999f));
    }

    private static Quaternion ResolveCorrection(
        Vector3 leftShoulder,
        Vector3 rightShoulder,
        Vector3 hips,
        Vector3 head)
    {
        Assert.That(Subject, Is.Not.Null);
        MethodInfo method = Subject.GetMethod(
            "ResolveCorrection",
            BindingFlags.Public | BindingFlags.Static);
        Assert.That(method, Is.Not.Null);
        return (Quaternion)method.Invoke(
            null,
            new object[]
            {
                leftShoulder,
                rightShoulder,
                hips,
                head,
            });
    }
}
