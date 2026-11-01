using System;
using System.Collections;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;

public sealed class PersistentWorldEnvironmentLifetimeTests
{
    private const string ControllerTypeName =
        "Maaso.World.PersistentWorldMapController, Assembly-CSharp";
    private const string PrefabPath =
        "Assets/MaasoWorld/Resources/PersonalSpaceMap.prefab";

    [Test]
    public void PersistentEnvironmentStaysVisibleWhileWorldDecorationsToggle()
    {
        GameObject instance = InstantiatePrefab();
        try
        {
            Type type = ControllerType();
            Component map = instance.GetComponent(type);
            Transform persistentRoot = Property<Transform>(map, "PersistentEnvironmentRoot");
            Transform decorationRoot = Property<Transform>(map, "WorldDecorationRoot");

            Assert.That(
                instance.transform.Find("PersistentEnvironmentRoot/BaseVisuals"),
                Is.Not.Null);
            Assert.That(
                instance.transform.Find("PersistentEnvironmentRoot/EnvironmentProps"),
                Is.Not.Null);

            type.GetMethod("SetWorldActive")?.Invoke(map, new object[] { false });
            Assert.That(persistentRoot.gameObject.activeSelf, Is.True);
            Assert.That(decorationRoot.gameObject.activeSelf, Is.False);

            type.GetMethod("SetWorldActive")?.Invoke(map, new object[] { true });
            Assert.That(persistentRoot.gameObject.activeSelf, Is.True);
            Assert.That(decorationRoot.gameObject.activeSelf, Is.True);
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(instance);
        }
    }

    [Test]
    public void RegistrationIsIdempotentAndFallbackSurvivesDestroyedPark()
    {
        GameObject instance = InstantiatePrefab();
        var park = new GameObject("ParkPersistentEnvironment");
        try
        {
            Type type = ControllerType();
            Component map = instance.GetComponent(type);
            Transform persistentRoot = Property<Transform>(map, "PersistentEnvironmentRoot");
            Transform homeAnchor = Property<Transform>(map, "HomeAgentAnchor");
            Transform playCenter = Property<Transform>(map, "WorldPlayCenter");
            Vector3 originalHomePosition = homeAnchor.position;
            Vector3 originalPlayPosition = playCenter.position;
            MethodInfo register = type.GetMethod(
                "RegisterPersistentEnvironment",
                BindingFlags.Public | BindingFlags.Instance);
            Assert.That(register, Is.Not.Null);

            register.Invoke(map, new object[] { park.transform });
            int childCountAfterFirstRegistration = persistentRoot.childCount;
            register.Invoke(map, new object[] { park.transform });

            Assert.That(park.transform.parent, Is.SameAs(persistentRoot));
            Assert.That(persistentRoot.childCount, Is.EqualTo(childCountAfterFirstRegistration));
            Assert.That(homeAnchor.position, Is.EqualTo(originalHomePosition));
            Assert.That(playCenter.position, Is.EqualTo(originalPlayPosition));

            UnityEngine.Object.DestroyImmediate(park);
            Assert.That(persistentRoot.gameObject.activeSelf, Is.True);
            Assert.That(
                instance.transform.Find("PersistentEnvironmentRoot/BaseVisuals")?.gameObject.activeSelf,
                Is.True);
            Assert.That(
                instance.transform.Find("PersistentEnvironmentRoot/EnvironmentProps")?.gameObject.activeSelf,
                Is.True);
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(instance);
            if (park != null)
            {
                UnityEngine.Object.DestroyImmediate(park);
            }
        }
    }

    [Test]
    public void PhysicalGroundIsTheOnlyStandingColliderAndEndsAtGroundY()
    {
        GameObject instance = InstantiatePrefab();
        try
        {
            Component map = instance.GetComponent(ControllerType());
            Collider physicalGround = Property<Collider>(map, "GroundCollider");
            Collider[] colliders = instance.GetComponentsInChildren<Collider>(true);

            Assert.That(colliders, Has.Exactly(1).SameAs(physicalGround));
            Assert.That(physicalGround.bounds.size.x, Is.EqualTo(8f).Within(0.001f));
            Assert.That(physicalGround.bounds.size.z, Is.EqualTo(8f).Within(0.001f));
            Assert.That(physicalGround.bounds.max.y, Is.EqualTo(0f).Within(0.001f));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(instance);
        }
    }

    private static GameObject InstantiatePrefab()
    {
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(PrefabPath);
        Assert.That(prefab, Is.Not.Null, PrefabPath);
        return UnityEngine.Object.Instantiate(prefab);
    }

    private static Type ControllerType()
    {
        Type type = Type.GetType(ControllerTypeName);
        Assert.That(type, Is.Not.Null, "PersistentWorldMapController should exist.");
        return type;
    }

    private static T Property<T>(object target, string name)
    {
        PropertyInfo property = target.GetType().GetProperty(
            name,
            BindingFlags.Public | BindingFlags.Instance);
        Assert.That(property, Is.Not.Null, name);
        return (T)property.GetValue(target);
    }
}
