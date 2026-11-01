using System;
using NUnit.Framework;
using UnityEngine;

public sealed class AgentSpaceRoomGeometryTests
{
    private static Type Geometry => Type.GetType("Maaso.World.CoastalPrivateWorldContract, Assembly-CSharp", true);

    [Test]
    public void BundledNavigationDigestRemainsStable()
    {
        string expected = (string)Geometry.GetField("LayoutDigest").GetRawConstantValue();
        Assert.That(Geometry.GetMethod("ComputeDigest").Invoke(null, null), Is.EqualTo(expected));
    }

    [TestCase(-.35f, .85f, 3.5f, 2.1f, true)]
    [TestCase(3.5f, 2.1f, 5.1f, 2.1f, true)]
    [TestCase(5.1f, 2.1f, 5.1f, 3.28f, true)]
    [TestCase(5.1f, 3.28f, 6.3f, 3.28f, true)]
    [TestCase(0f, 0f, 6f, 3.9f, false)]
    [TestCase(5.1f, 2.1f, 6.3f, 2.1f, false)]
    [TestCase(0f, 0f, 6f, -1f, false)]
    [TestCase(5.1f, 2.1f, 6.3f, 3.28f, false)]
    public void RoomSegmentsRespectTheCompleteFloorAndPhysicalBed(float x, float z, float toX, float toZ, bool allowed)
    {
        Assert.That(Geometry.GetMethod("SegmentAllowed").Invoke(null,
            new object[] { new Vector3(x, 0, z), new Vector3(toX, 0, toZ) }), Is.EqualTo(allowed));
    }

    [TestCase(6f, -1f, false)]
    [TestCase(4.1f, .8f, false)]
    [TestCase(6.3f, 2.1f, false)]
    [TestCase(6.3f, 3.28f, true)]
    public void RoomPointsRespectTheBedroomAndBlockers(float x, float z, bool allowed)
    {
        Assert.That(Geometry.GetMethod("ContainsPoint").Invoke(null, new object[] { new Vector3(x, 0, z) }), Is.EqualTo(allowed));
    }
}
