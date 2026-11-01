#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;
using Maaso.Avatar;

namespace Maaso.Editor
{
    /// <summary>Scene-local interaction metadata only. Furniture art belongs to
    /// the reviewed Blender room; this builder never substitutes primitive art.</summary>
    public static class PersonalSpaceFurnitureBuilder
    {
        public const string PrefabPath = "Assets/MaasoWorld/Editor/Legacy/PersonalSpaceFurniture.prefab";

        public static void Build()
        {
            var root = new GameObject("PersonalSpaceFurniture");
            try
            {
                var rig = root.AddComponent<AvatarFurnitureRig>();
                var sofa = Anchor(root.transform,"sofa",new Vector3(-2.77f,.60f,-1.48f),90,new Vector3(-2.47f,0,-1.48f),
                    new[]{new Vector3(-.8f,0,.25f),new Vector3(-2.47f,0,.25f)});
                var chair = Anchor(root.transform,"chair",new Vector3(2.42f,.54f,-2.62f),-45,new Vector3(1.81f,0,-1.97f),
                    new[]{new Vector3(.7f,0,-1.25f)});
                var desk = Anchor(root.transform,"desk",new Vector3(-2.65f,.53f,2.24f),0,new Vector3(-2.65f,0,1.55f),
                    new[]{new Vector3(-1.0f,0,1.0f),new Vector3(-2.65f,0,1.0f)});
                desk.WorkSurface = Point(root.transform,"desk-work-surface",new Vector3(-2.65f,.84f,2.9f),0);
                // No bed capability until the Blender bedroom layout and its
                // measured surface/entry/path anchors have been published.
                rig.Anchors = new[] { sofa, chair, desk };
                PrefabUtility.SaveAsPrefabAsset(root, PrefabPath);
                AssetDatabase.SaveAssets();
            }
            finally { Object.DestroyImmediate(root); }
        }
        private static AvatarFurnitureAnchor Anchor(Transform root,string id,Vector3 seat,float yaw,Vector3 approach,Vector3[] waypoints)
        {
            var result = new AvatarFurnitureAnchor {Id=id, Seat=Point(root,id+"-seat",seat,yaw), Approach=Point(root,id+"-approach",approach,yaw)};
            result.Waypoints = new Transform[waypoints.Length];
            for(int i=0;i<waypoints.Length;i++) result.Waypoints[i]=Point(root,id+"-path-"+i,waypoints[i],yaw);
            return result;
        }
        private static Transform Point(Transform root,string name,Vector3 position,float yaw)
        { var item=new GameObject(name); item.transform.SetParent(root,false); item.transform.localPosition=position; item.transform.localRotation=Quaternion.Euler(0,yaw,0); return item.transform; }
    }
}
#endif
