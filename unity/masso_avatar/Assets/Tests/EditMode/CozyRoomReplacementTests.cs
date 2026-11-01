using System;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class CozyRoomReplacementTests
{
    [Test]
    public void BaseSpaceKeepsGroundAndAnchorsWithoutRetiredWhiteboxGeometry()
    {
        Type controllerType = Type.GetType(
            "Maaso.World.PersistentWorldMapController, Assembly-CSharp");
        Assert.That(controllerType, Is.Not.Null);
        MethodInfo build = controllerType.GetMethod(
            "BuildDefaultMap", BindingFlags.Public | BindingFlags.Static);
        Assert.That(build, Is.Not.Null);
        var root = new GameObject("CozyRoomReplacementTest");
        try
        {
            Component controller = (Component)build.Invoke(null, new object[] { root });
            Assert.That(controller, Is.Not.Null);
            AssertNoRetiredGeometry(root);
            Transform visuals = root.transform.Find(
                "PersistentEnvironmentRoot/BaseVisuals/WhiteboxVisuals");
            Assert.That(visuals, Is.Not.Null,
                "Recovery must keep the destination for the bundled cozy-room model.");
            Assert.That(visuals.GetComponentsInChildren<Renderer>(true), Is.Empty,
                "A missing prefab must never recreate the retired block scenery.");

            // EditMode has no physics tick between creating/scaling the ground
            // and reading its world bounds.
            Physics.SyncTransforms();
            Collider[] colliders = root.GetComponentsInChildren<Collider>(true);
            Assert.That(colliders, Has.Length.EqualTo(1));
            Assert.That(colliders[0].name, Is.EqualTo("WorldGround"));
            Assert.That(colliders[0].bounds.max.y, Is.EqualTo(0f).Within(0.001f));
            Assert.That(colliders[0].bounds.size.x, Is.EqualTo(8f).Within(0.001f));
            Assert.That(colliders[0].bounds.size.z, Is.EqualTo(8f).Within(0.001f));
            Assert.That(root.transform.Find("HomeAgentAnchor"), Is.Not.Null);
            Assert.That(root.transform.Find("HomeCameraReference"), Is.Not.Null);
            Assert.That(root.transform.Find("WorldPlayCenter"), Is.Not.Null);
            Assert.That(root.transform.Find("WorldSpawnAnchors").childCount,
                Is.EqualTo(8));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(root);
        }
    }

    [TestCase("PersonalSpaceModel")]
    [TestCase("PersonalSpaceMap")]
    public void SynchronousResourcesContainTheReplacementRoom(string resourceName)
    {
        GameObject resource = Resources.Load<GameObject>(resourceName);
        Assert.That(resource, Is.Not.Null, resourceName);
        AssertNoRetiredGeometry(resource);
        Renderer[] renderers = resource.GetComponentsInChildren<Renderer>(true);
        foreach (string meshName in new[]
                 {
                     "V2_Floor_Baked", "V2_Sheer_Curtain_West",
                     "V2_Sofa_Baked", "V2_Distant_Ocean",
                 })
        {
            Renderer renderer = renderers.SingleOrDefault(value => value.name == meshName);
            Assert.That(renderer, Is.Not.Null,
                resourceName + " must contain the cozy room's " + meshName);
            MeshFilter filter = renderer.GetComponent<MeshFilter>();
            Assert.That(filter, Is.Not.Null, meshName);
            Assert.That(filter.sharedMesh, Is.Not.Null, meshName);
            Assert.That(filter.sharedMesh.vertexCount, Is.GreaterThan(0), meshName);
            Assert.That(renderer.sharedMaterials, Is.Not.Empty, meshName);
            Assert.That(renderer.sharedMaterials, Has.None.Null, meshName);
        }
        Material[] materials = renderers.SelectMany(value => value.sharedMaterials)
            .Where(value => value != null).Distinct().ToArray();
        Assert.That(materials.Length, Is.GreaterThanOrEqualTo(12),
            "The replacement must retain its wood, fabric and greenery materials.");
    }

    private static void AssertNoRetiredGeometry(GameObject root)
    {
        string[] retiredNames = root.GetComponentsInChildren<Transform>(true)
            .Select(value => value.name)
            .Where(value => value == "WhiteboxFoundation" ||
                value.StartsWith("WhiteboxBlock-", StringComparison.Ordinal))
            .ToArray();
        Assert.That(retiredNames, Is.Empty,
            "The replaced whitebox scenery must not remain active or hidden.");
    }
}
