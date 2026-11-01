using System;
using System.Collections.Generic;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using Object=UnityEngine.Object;

public sealed class CoastalV4RuntimeAssetTests
{
    private static Type W(string name)=>Type.GetType("Maaso.World."+name+", Assembly-CSharp",true);
    private static Type A(string name)=>Type.GetType("Maaso.Avatar."+name+", Assembly-CSharp",true);
    private static object Call(object target,string method,params object[] args)=>target.GetType().GetMethod(method).Invoke(target,args);
    private static object Field(object target,string name)=>target.GetType().GetField(name,BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance).GetValue(target);
    private static void Set(object target,string name,object value)=>target.GetType().GetField(name,BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance).SetValue(target,value);
    private static object Property(object target,string name)=>target.GetType().GetProperty(name).GetValue(target);

    [Test] public void PublishedRoomHasOneSharedEntryAndRealBedroomFloorWithReachableBed()
    {
        var root=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        try
        {
            var map=root.GetComponent(W("PersistentWorldMapController"));Call(map,"SetWorldActive",false);
            var nav=root.GetComponentInChildren(A("PersonalSpaceNavigation"));
            Assert.That(W("CoastalPrivateWorldContract").GetMethod("ValidateNavigation").Invoke(null,new object[]{nav}),Is.True);
            var names=root.GetComponentsInChildren<Transform>(true).Select(t=>t.name).ToArray();
            Assert.That(names.Count(n=>n=="V4_EntryLeaf"),Is.EqualTo(1));Assert.That(names.Count(n=>n=="V4_EntryHinge"),Is.EqualTo(1));
            Assert.That(names.Any(n=>n=="V2_Entrance_Door"||n=="V2_Entrance_Baked"||n=="PersonalSpaceFurniture"),Is.False);
            var ground=root.GetComponentsInChildren<MeshCollider>().Single(c=>c.name=="V4WalkableFloor");
            Assert.That(ground.Raycast(new Ray(new Vector3(6.3f,1,3.28f),Vector3.down),out _,2),Is.True);
            Assert.That(ground.Raycast(new Ray(new Vector3(6,1,-2),Vector3.down),out _,2),Is.False);
            Assert.That((bool)Call(nav,"ContainsFoot",new Vector3(4.1f,0,2.1f)),Is.True,"A .18 m actor must fit the union portal.");
            Assert.That((bool)Call(nav,"ContainsFoot",new Vector3(6.3f,0,2.1f)),Is.False,"The physical bed blocks movement.");
            var rig=nav.GetComponent(A("AvatarFurnitureRig"));var bed=Call(rig,"Find","bed");
            var start=(Transform)Property(map,"HomeAgentAnchor");var approach=(Transform)Field(bed,"Approach");
            object[] args={start.position,approach.position,null,null};Assert.That(Call(nav,"TryBuildRoute",args),Is.True);
            var path=(List<Vector3>)args[3];Assert.That(path.Count,Is.GreaterThan(1));
            Vector3 last=start.position;foreach(var point in path){Assert.That((bool)Call(nav,"SegmentIsClear",last,point),Is.True);last=point;}
            Assert.That((bool)Call(nav,"CrossesBedroomPortal",start.position,path),Is.True);
            var door=Field(nav,"BedroomDoor");Assert.That((bool)Property(door,"IsOpen"),Is.False);Call(door,"RequestOpen");Call(door,"Advance",1f);
            Assert.That((bool)Property(door,"IsOpen"),Is.True);
        }
        finally{Object.DestroyImmediate(root);}
    }

    [Test] public void PublishedRoomDoorwayCanRouteTheCameraToTheHomeAvatar()
    {
        var root=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        var cameraObject=new GameObject("PublishedDoorwayCamera");
        var actor=Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        try
        {
            var map=root.GetComponent(W("PersistentWorldMapController"));Call(map,"SetWorldActive",false);
            var rig=A("LoginDoorwayRig").GetMethod("Ensure").Invoke(null,new[]{map});
            Assert.That(rig,Is.Not.Null,"The published room must expose exactly one valid entry rig.");
            actor.transform.position=((Transform)Property(map,"HomeAgentAnchor")).position;
            var camera=cameraObject.AddComponent<Camera>();camera.aspect=.5f;
            var framing=cameraObject.AddComponent(A("FrontFullBodyCamera"));
            framing.GetType().GetProperty("TargetRoot").SetValue(framing,actor.transform);
            Call(framing,"SetHomeViewReference",Property(map,"HomeCameraReference"));Call(framing,"FrameNow");
            object[] framingArgs={rig,Activator.CreateInstance(A("CameraPose")),0f};
            Assert.That(Call(framing,"TryGetDoorwayFramingPose",framingArgs),Is.True,"The real avatar needs a room-safe final camera pose.");
            Vector3 final=(Vector3)Property(framingArgs[1],"Position");
            var shelf=root.GetComponentsInChildren<Renderer>(true).Single(value=>value.name=="V4_Bookshelf_Baked");
            Assert.That(shelf.bounds.min.z-final.z,Is.GreaterThan(.25f),
                "The Joy doorway endpoint must stay inside the bookcase clearance plane.");
            Assert.That(final.z,Is.LessThanOrEqualTo(((Transform)Property(map,"HomeCameraReference")).position.z+.02f),
                "Doorway framing must use the same reviewed Home camera depth limit.");
            Vector3 lobby=(Vector3)Call(rig,"EntryDestination",final);
            var navigation=Property(rig,"Navigation");
            Assert.That(navigation,Is.Not.Null,"The entry must bind the published navigation revision.");
            object[] routeArgs={lobby,final,null};
            Assert.That(Call(navigation,"TryBuildCameraRoute",routeArgs),Is.True,"The camera must have a real path from the lobby to the avatar.");
            var route=(List<Vector3>)routeArgs[2];
            Assert.That(route.Count,Is.GreaterThan(0));
            Assert.That(Vector3.Distance(lobby,final),Is.GreaterThan(.5f));

            // Doorway ownership disables normal framing. Both owners must use
            // the same full-body endpoint, and the first Home frames must not
            // back away from the actor or jitter in response to layout updates.
            ((Behaviour)framing).enabled=false;
            object[] disabledArgs={rig,Activator.CreateInstance(A("CameraPose")),0f};
            Assert.That(Call(framing,"TryGetDoorwayFramingPose",disabledArgs),Is.True);
            var disabledPose=disabledArgs[1];
            Assert.That(Vector3.Distance((Vector3)Property(disabledPose,"Position"),final),Is.LessThan(.001f));
            Assert.That((float)disabledArgs[2],Is.EqualTo((float)framingArgs[2]).Within(.001f));
            camera.transform.SetPositionAndRotation(final,(Quaternion)Property(disabledPose,"Rotation"));
            camera.fieldOfView=(float)disabledArgs[2];
            Call(framing,"CompleteDoorwayCameraRoute",rig);
            ((Behaviour)framing).enabled=true;
            Vector3 landedPosition=camera.transform.position;
            Quaternion landedRotation=camera.transform.rotation;
            float landedFieldOfView=camera.fieldOfView;
            for(int frame=0;frame<180;frame++)Call(framing,"AdvanceFraming",1f/60f);
            Call(framing,"SetViewportSafeArea",.15f,.2f);
            Assert.That(Vector3.Distance(camera.transform.position,landedPosition),Is.LessThan(.001f));
            Assert.That(Quaternion.Angle(camera.transform.rotation,landedRotation),Is.LessThan(.01f));
            Assert.That(camera.fieldOfView,Is.EqualTo(landedFieldOfView).Within(.001f));
        }
        finally{Object.DestroyImmediate(actor);Object.DestroyImmediate(cameraObject);Object.DestroyImmediate(root);}
    }

    [Test] public void EnteringHomeEndsAtTheFullBodyShotBeforeFrameCompletes()
    {
        var root=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        var actor=Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
        var cameraObject=new GameObject("OneTakeDoorwayCamera");
        try
        {
            var map=root.GetComponent(W("PersistentWorldMapController"));Call(map,"SetWorldActive",false);
            actor.transform.position=((Transform)Property(map,"HomeAgentAnchor")).position;
            var rig=A("LoginDoorwayRig").GetMethod("Ensure").Invoke(null,new[]{map});
            var camera=cameraObject.AddComponent<Camera>();camera.aspect=900f/1950f;
            var framing=cameraObject.AddComponent(A("FrontFullBodyCamera"));
            framing.GetType().GetProperty("TargetRoot").SetValue(framing,actor.transform);
            Call(framing,"SetHomeViewReference",Property(map,"HomeCameraReference"));
            Call(framing,"SetViewportSafeArea",.16f,.133f);
            Call(framing,"SetFramingMode","hero_full_body");
            object[] expectedArgs={rig,Activator.CreateInstance(A("CameraPose")),0f};
            Assert.That(Call(framing,"TryGetDoorwayFramingPose",expectedArgs),Is.True);
            Vector3 expected=(Vector3)Property(expectedArgs[1],"Position");
            float expectedFov=(float)expectedArgs[2];

            var receipts=new List<JObject>();
            Action<object> onResult=value=>receipts.Add(JObject.Parse(JsonUtility.ToJson(value)));
            Type resultType=A("LoginDoorwayResult"),commandType=A("LoginDoorwayCommand");
            var parameter=Expression.Parameter(resultType);
            Delegate callback=Expression.Lambda(typeof(Action<>).MakeGenericType(resultType),
                Expression.Invoke(Expression.Constant(onResult),Expression.Convert(parameter,typeof(object))),parameter).Compile();
            object transition=Activator.CreateInstance(A("LoginDoorwayTransitionController"),callback);
            int sequence=0;
            void Phase(string phase,int duration,float now)
            {
                string command="{\"requestId\":\"one-take-"+phase+"\",\"transitionId\":\"one-take\",\"phase\":\""+phase+
                    "\",\"durationMs\":"+duration+",\"sequence\":"+(++sequence)+",\"expiresAtMs\":60000}";
                Call(transition,"Execute",JsonUtility.FromJson(command,commandType),framing,rig,true,now,1000L);
            }
            Phase("prepare",0,0);Phase("open",650,0);Call(transition,"Advance",.65f,1000L);
            Phase("enter",1200,.65f);Call(transition,"Advance",1.86f,1000L);
            Assert.That(Vector3.Distance(camera.transform.position,expected),Is.LessThan(.01f),
                "The entering camera must already show the final full-body pose.");
            Assert.That(camera.fieldOfView,Is.EqualTo(expectedFov).Within(.01f),
                "Frame must not zoom out after entering the room.");
            Vector3 enteringEnd=camera.transform.position;float enteringFov=camera.fieldOfView;
            Phase("frame",300,1.86f);
            for(int frame=1;frame<=60&&(bool)Property(transition,"OwnsCamera");frame++)
                Call(transition,"Advance",1.86f+frame/60f,1000L+frame*1000L/60);
            Assert.That((bool)Property(transition,"OwnsCamera"),Is.False);
            Assert.That(Vector3.Distance(camera.transform.position,enteringEnd),Is.LessThan(.001f));
            Assert.That(camera.fieldOfView,Is.EqualTo(enteringFov).Within(.001f));
            Assert.That(receipts.All(receipt=>(bool)receipt["ok"]),Is.True,
                string.Join(", ",receipts.Select(receipt=>receipt.ToString())));
        }
        finally{Object.DestroyImmediate(cameraObject);Object.DestroyImmediate(actor);Object.DestroyImmediate(root);}
    }

    [Test] public void PrivateWorldTakeoverReleasesSleepingJoyToTheReviewedFloorApproach()
    {
        var root=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));
        var host=new GameObject("SleepingPrivateOwner");
        try
        {
            var map=root.GetComponent(W("PersistentWorldMapController"));Call(map,"SetWorldActive",false);
            var actor=Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"),host.transform);
            actor.transform.position=((Transform)Property(map,"HomeAgentAnchor")).position;
            var animator=actor.GetComponentInChildren<Animator>();animator.runtimeAnimatorController=AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");animator.Rebind();animator.Update(0);animator.enabled=false;
            var receiver=host.AddComponent(A("UnityAvatarCommandReceiver"));Set(receiver,"avatarRoot",actor.transform);Set(receiver,"bundledAvatarRoot",actor.transform);
            var nav=root.GetComponentInChildren(A("PersonalSpaceNavigation"));var rig=nav.GetComponent(A("AvatarFurnitureRig"));
            var controller=Field(receiver,"furniturePose");
            var originalBones=actor.GetComponentsInChildren<Transform>().Select(t=>(bone:t,position:t.localPosition,rotation:t.localRotation)).ToArray();
            Assert.That((bool)Call(controller,"Begin","lie_bed",actor.transform,animator,rig,0f,(Action<string>)(_=>{}),(Action<bool>)(_=>{})),Is.True);
            foreach(var pose in originalBones)
            {
                Assert.That(Vector3.Distance(pose.bone.localPosition,pose.position),Is.LessThan(.000001f),"Support calibration must not expose its temporary probe pose.");
                Assert.That(Quaternion.Angle(pose.bone.localRotation,pose.rotation),Is.LessThan(.01f));
            }
            for(int frame=0;frame<=1800;frame++){Call(Field(nav,"BedroomDoor"),"Advance",1f/60);Call(controller,"Advance",frame/60f,1f/60);}
            Assert.That(Property(controller,"Phase"),Is.EqualTo("lying"));
            Call(receiver,"PrepareHomeOwnerForAgentSpace");
            Assert.That(Property(controller,"Phase"),Is.EqualTo("standing"));Assert.That((bool)Call(nav,"ContainsFoot",actor.transform.position),Is.True);
            var bed=Call(rig,"Find","bed");Assert.That(Vector3.Distance(actor.transform.position,((Transform)Field(bed,"Approach")).position),Is.LessThan(.001f));
        }
        finally{Object.DestroyImmediate(host);Object.DestroyImmediate(root);}
    }

    [Test] public void ColdHomeFramingFollowsTheExistingActorThroughBedroomDoorWithoutLogin()
    {
        var root=Object.Instantiate(Resources.Load<GameObject>("PersonalSpaceMap"));var cameraObject=new GameObject("ColdHomeCamera");
        var actor=Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));object posture=null;
        try
        {
            var map=root.GetComponent(W("PersistentWorldMapController"));Call(map,"SetWorldActive",false);
            actor.transform.position=((Transform)Property(map,"HomeAgentAnchor")).position;
            var camera=cameraObject.AddComponent<Camera>();camera.aspect=.5f;camera.transform.position=new Vector3(0,1.4f,3);
            var framing=cameraObject.AddComponent(A("FrontFullBodyCamera"));framing.GetType().GetProperty("TargetRoot").SetValue(framing,actor.transform);
            Call(framing,"SetHomeViewReference",Property(map,"HomeCameraReference"));Call(framing,"FrameNow");
            var nav=root.GetComponentInChildren(A("PersonalSpaceNavigation"));var rig=nav.GetComponent(A("AvatarFurnitureRig"));var animator=actor.GetComponentInChildren<Animator>();
            animator.runtimeAnimatorController=AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller");
            animator.Rebind();animator.Play("idle_shrug",0,.25f);animator.Update(0);
            posture=Activator.CreateInstance(A("AvatarFurniturePoseController"));
            Action<string> phase=value=>{Call(framing,"SetFurniturePoseActive",value!="standing");if(value=="lying")Call(framing,"SetFramingMode","sleeping_top");};
            Assert.That(Call(posture,"Begin","lie_bed",actor.transform,animator,rig,0f,phase,(Action<bool>)(_=>{})),Is.True);
            for(int frame=0;frame<2400;frame++)
            {
                animator.Update(1f/60);Call(Field(nav,"BedroomDoor"),"Advance",1f/60);Call(posture,"Advance",frame/60f,1f/60);Call(framing,"AdvanceFraming",1f/60);
                Assert.That(Call(nav,"ContainsCamera",camera.transform.position,.08f),Is.True);
            }
            Assert.That(Property(posture,"Phase"),Is.EqualTo("lying"));Assert.That(camera.transform.position.x,Is.GreaterThan(4.2f));
            Assert.That(Vector3.Dot(camera.transform.forward,Vector3.down),Is.GreaterThan(.85f));
        }
        finally{if(posture!=null)Call(posture,"Reset",false);Object.DestroyImmediate(actor);Object.DestroyImmediate(cameraObject);Object.DestroyImmediate(root);}
    }

}
