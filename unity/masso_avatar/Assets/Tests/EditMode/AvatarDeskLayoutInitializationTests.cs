using System;
using System.Linq;
using NUnit.Framework;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object=UnityEngine.Object;

public sealed class AvatarDeskLayoutInitializationTests
{
    private GameObject room;
    private static Type RigType=>Type.GetType("Maaso.Avatar.AvatarFurnitureRig, Assembly-CSharp",true);
    private static object Desk(Component rig)=>RigType.GetMethod("Find").Invoke(rig,new object[]{"desk"});
    private static Transform Point(Component rig,string name)=>(Transform)Desk(rig).GetType().GetField(name).GetValue(Desk(rig));

    [Test]
    public void InitialRoomAlignsBeforeAnyFurnitureActionAndRepeatedEnsureDoesNotMoveItAgain()
    {
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);
        GameObject source=Resources.Load<GameObject>("PersonalSpaceMap");
        Component sourceRig=source.GetComponentInChildren(RigType);
        Vector3 sourceSeat=Point(sourceRig,"Seat").localPosition;
        Vector3 sourceSurface=Point(sourceRig,"WorkSurface").localPosition;
        MeshFilter sourceDesk=source.GetComponentsInChildren<MeshFilter>(true).Single(value=>value.name=="V4_WorkDesk_Baked");
        Mesh sourceMesh=sourceDesk.sharedMesh;
        room=Object.Instantiate(source);
        Component rig=room.GetComponentInChildren(RigType);
        // EditMode does not dispatch normal runtime Awake consistently; invoke
        // that exact entry when needed instead of simulating a furniture action.
        if(!(bool)RigType.GetProperty("HasDeskKeyboard").GetValue(rig))
            RigType.GetMethod("Awake",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic).Invoke(rig,null);
        Assert.That(RigType.GetProperty("HasDeskKeyboard").GetValue(rig),Is.EqualTo(true));
        Bounds keys=(Bounds)RigType.GetProperty("DeskKeyboardBounds").GetValue(rig);
        Transform seat=Point(rig,"Seat"),surface=Point(rig,"WorkSurface");
        Transform chair=room.GetComponentsInChildren<MeshFilter>(true).Single(value=>value.name=="V4_WorkChair_Baked").transform;
        Vector3 chairPosition=chair.localPosition,seatPosition=seat.localPosition,surfacePosition=surface.localPosition;
        Assert.That(seat.position.x,Is.EqualTo(keys.center.x).Within(.002f));
        Assert.That(chair.localPosition.x,Is.EqualTo(.18f).Within(.002f));
        Assert.That(chair.localPosition.z,Is.EqualTo(.24f).Within(.002f));
        Assert.That(seat.localPosition.z-sourceSeat.z,Is.EqualTo(.24f).Within(.002f));
        for(int attempt=0;attempt<3;attempt++)
        {
            Assert.That(RigType.GetMethod("EnsureDeskWorkLayout").Invoke(rig,null),Is.EqualTo(true));
            Assert.That(chair.localPosition,Is.EqualTo(chairPosition));
            Assert.That(seat.localPosition,Is.EqualTo(seatPosition));
            Assert.That(surface.localPosition,Is.EqualTo(surfacePosition));
        }
        Assert.That(Point(sourceRig,"Seat").localPosition,Is.EqualTo(sourceSeat));
        Assert.That(Point(sourceRig,"WorkSurface").localPosition,Is.EqualTo(sourceSurface));
        Assert.That(sourceDesk.sharedMesh,Is.SameAs(sourceMesh));
        Assert.That(room.GetComponentsInChildren<MeshFilter>(true).Single(value=>value.name=="V4_WorkDesk_Baked").sharedMesh,Is.SameAs(sourceMesh),
            "Moving the chair must not clone or rewrite the laptop's authored mesh/UV atlas.");
    }

    [TearDown] public void TearDown()
    {
        if(room!=null)Object.DestroyImmediate(room);
        EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);
    }
}
