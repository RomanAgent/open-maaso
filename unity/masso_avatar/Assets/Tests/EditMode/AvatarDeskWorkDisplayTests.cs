using System;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarDeskWorkDisplayTests
{
    private GameObject room;
    private object anchor;
    private Component display;
    private Type DisplayType => Type.GetType("Maaso.Avatar.AvatarDeskWorkDisplay, Assembly-CSharp", true);
    private Type RigType => Type.GetType("Maaso.Avatar.AvatarFurnitureRig, Assembly-CSharp", true);
    private object Value(string property) => DisplayType.GetProperty(property).GetValue(display);
    private void Call(string method, params object[] values) => DisplayType.GetMethod(method).Invoke(display, values);
    private Component Ensure(object value) => (Component)DisplayType.GetMethod("Ensure").Invoke(null, new[] { value });
    private void Lifecycle(string name) => DisplayType.GetMethod(name,
        BindingFlags.Instance | BindingFlags.NonPublic).Invoke(display, null);

    [SetUp]
    public void Create()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
        room = Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        Assert.That(room, Is.Not.Null);
        var rig = room.GetComponentInChildren(RigType);
        Assert.That(rig, Is.Not.Null);
        anchor = RigType.GetMethod("Find").Invoke(rig, new object[] { "desk" });
        Assert.That(anchor, Is.Not.Null);
        display = Ensure(anchor);
        Assert.That(display, Is.Not.Null, "Reviewed non-readable screen bounds and room anchors must bind.");
    }

    [TearDown]
    public void Cleanup()
    {
        if (display != null) Call("Dispose");
        if (room != null) Object.DestroyImmediate(room);
    }

    [Test]
    public void IdleAllocatesNoWorkTextureAndRetainsOriginalScreenMaterial()
    {
        var source = (MeshRenderer)Value("SourceRenderer");
        Material original = source.sharedMaterial;
        Assert.That((bool)Value("IsLit"), Is.False);
        Assert.That(Value("DisplayTexture"), Is.Null);
        Assert.That(Value("DisplayRenderer"), Is.Null);
        Call("SetWorking", false);
        Assert.That(source.sharedMaterial, Is.SameAs(original));
        Assert.That(Ensure(anchor), Is.SameAs(display), "One scene-local component per real screen.");
    }

    [Test]
    public void WorkDisplayFacesTheSeatAndFitsInsideReviewedGlassWithoutChangingIt()
    {
        var source = (MeshRenderer)Value("SourceRenderer");
        Material original = source.sharedMaterial;
        var sourceMesh = source.GetComponent<MeshFilter>().sharedMesh;
        Call("SetWorking", true);
        Assert.That((bool)Value("IsLit"), Is.True);
        var visible = (MeshRenderer)Value("DisplayRenderer");
        Assert.That(visible, Is.Not.Null);
        Assert.That(visible.transform.parent, Is.SameAs(source.transform));
        Assert.That(visible.sharedMaterial.shader.name, Is.EqualTo("Maaso/DeskWorkDisplay"));
        Assert.That(source.sharedMaterial, Is.SameAs(original));
        Assert.That(source.GetComponent<MeshFilter>().sharedMesh, Is.SameAs(sourceMesh));
        var mesh = visible.GetComponent<MeshFilter>().sharedMesh;
        Transform seat = (Transform)anchor.GetType().GetField("Seat").GetValue(anchor);
        Vector3 normal = visible.transform.TransformDirection(mesh.normals[0]);
        Assert.That(Vector3.Dot(normal, seat.position - visible.bounds.center), Is.GreaterThan(0));
        Assert.That(mesh.bounds.size.x, Is.LessThan(sourceMesh.bounds.size.x));
        Assert.That(mesh.bounds.size.y, Is.LessThan(sourceMesh.bounds.size.y));
        var vertices = mesh.vertices;
        Assert.That(vertices[1].x, Is.GreaterThan(vertices[0].x), "UI must not mirror left and right.");
        Assert.That(Vector3.Dot(Vector3.Cross(vertices[2]-vertices[0], vertices[1]-vertices[0]),
            mesh.normals[0]), Is.GreaterThan(0), "Front winding must agree with its viewer-facing normal.");
    }

    [Test]
    public void AnimationReusesTextureAndIsThrottledWithoutASeparateUpdateLoop()
    {
        Call("SetWorking", true);
        var texture = (Texture2D)Value("DisplayTexture");
        var start = texture.GetPixels32();
        Call("Advance", 10f);
        var first = texture.GetPixels32();
        Call("Advance", 10.01f);
        Assert.That(texture.GetPixels32(), Is.EqualTo(first));
        Call("Advance", 10.2f);
        Assert.That(texture.GetPixels32().SequenceEqual(first), Is.False);
        Assert.That(texture.GetPixels32().SequenceEqual(start), Is.False);
        Assert.That(Value("DisplayTexture"), Is.SameAs(texture));
    }

    [Test]
    public void WorkEndImmediatelyBlanksAndReleasesEveryOwnedResource()
    {
        Call("SetWorking", true);
        var visible = (MeshRenderer)Value("DisplayRenderer");
        var mesh = visible.GetComponent<MeshFilter>().sharedMesh;
        var material = visible.sharedMaterial;
        var texture = (Texture2D)Value("DisplayTexture");
        Call("SetWorking", false);
        Assert.That((bool)Value("IsLit"), Is.False);
        Assert.That(Value("DisplayTexture"), Is.Null);
        Assert.That(Value("DisplayRenderer"), Is.Null);
        Assert.That(mesh == null, Is.True);
        Assert.That(material == null, Is.True);
        Assert.That(texture == null, Is.True);
        Call("Advance", 11f);
        Assert.That(Value("DisplayTexture"), Is.Null);
        Call("SetWorking", true);
        Assert.That((bool)Value("IsLit"), Is.True, "A later valid work pose can rebuild its local resources.");
    }

    [Test]
    public void HiddenSceneAndDisabledComponentCannotLeaveTheComputerLit()
    {
        Call("SetWorking", true);
        room.SetActive(false);
        Assert.That((bool)Value("IsLit"), Is.False);
        // EditMode does not dispatch normal play lifecycle messages. The
        // hierarchy check above proves immediate visibility; dispatch the
        // real callback explicitly to verify its separate resource cleanup.
        Lifecycle("OnDisable");
        Assert.That(Value("DisplayTexture"), Is.Null);
        room.SetActive(true);
        display = Ensure(anchor);
        Call("SetWorking", true);
        ((Behaviour)display).enabled = false;
        Assert.That((bool)Value("IsLit"), Is.False);
        Lifecycle("OnDisable");
        Assert.That(Value("DisplayTexture"), Is.Null);
        Call("SetWorking", true);
        Assert.That((bool)Value("IsLit"), Is.False);
    }

    [Test]
    public void SourceRendererSuppressionIsObservedAndCleanedOnTheNextOwnedFrame()
    {
        Call("SetWorking", true);
        var source = (MeshRenderer)Value("SourceRenderer");
        var texture = (Texture2D)Value("DisplayTexture");
        source.enabled = false;
        Assert.That((bool)Value("IsLit"), Is.False);
        Call("Advance", 10f);
        Assert.That(Value("DisplayTexture"), Is.Null);
        Assert.That(texture == null, Is.True);
        source.enabled = true;
        Call("SetWorking", true);
        Assert.That((bool)Value("IsLit"), Is.True);
    }

    [Test]
    public void InvalidOrAmbiguousScreenBindingFailsWithoutPrimitiveFallback()
    {
        Assert.That(Ensure(null), Is.Null);
        var source = (MeshRenderer)Value("SourceRenderer");
        var duplicate = Object.Instantiate(source.gameObject, source.transform.parent);
        duplicate.name = source.name;
        Assert.That(Ensure(anchor), Is.Null);
        Object.DestroyImmediate(duplicate);
        var surfaceField = anchor.GetType().GetField("WorkSurface");
        var saved = surfaceField.GetValue(anchor);
        surfaceField.SetValue(anchor, null);
        Assert.That(Ensure(anchor), Is.Null);
        surfaceField.SetValue(anchor, saved);
    }
}
