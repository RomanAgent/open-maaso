using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using Maaso.Avatar;
using UnityEngine;

namespace Maaso.World
{
    [Serializable] public sealed class WorldRoomRegion { public string id;public WorldMapPlayableBounds bounds; }
    [Serializable] public sealed class WorldRoomSpawn { public float x,z; }

    /// <summary>Bundled personal-room geometry. Digest identifies navigation, not artwork.</summary>
    public static class CoastalPrivateWorldContract
    {
        public const int LayoutRevision=1;
        public const string LayoutDigest="f75564292ad884405fcdafea5007aad4acdee70eaed396a62d70c71460f42815";
        public const string CanonicalUtf8="maaso-private-layout-v1\ncoastal_home_v4\n1\n4\nwalk_only\nbounds:-400,-400,780,400\nregion:main:-400,-400,400,400\nregion:bedroom:420,40,780,400\nregion:bedroom_portal:400,160,420,260\nblocker:bed:545,125,765,295\nspawn:-35,85\n";
        public static WorldMapPlayableBounds Bounds=>Box(-4,7.8f,-4,4);
        public static WorldMapPlayableBounds Bed=>Box(5.45f,7.65f,1.25f,2.95f);
        public static WorldRoomRegion[] Regions=>new[]{new WorldRoomRegion{id="main",bounds=Box(-4,4,-4,4)},new WorldRoomRegion{id="bedroom",bounds=Box(4.2f,7.8f,.4f,4)},new WorldRoomRegion{id="bedroom_portal",bounds=Box(4,4.2f,1.6f,2.6f)}};
        private static WorldMapPlayableBounds Box(float x0,float x1,float z0,float z1)=>new(){minX=x0,maxX=x1,minZ=z0,maxZ=z1};
        public static bool ContainsPoint(Vector3 point)
        {
            if(!Finite(point.x)||!Finite(point.z))return false;
            bool floor=false;foreach(var region in Regions)if(region.bounds.Contains(point)){floor=true;break;}
            return floor&&!Interior(Bed,point);
        }
        public static bool SegmentAllowed(Vector3 from,Vector3 to)
        {
            if(!ContainsPoint(from)||!ContainsPoint(to))return false;
            var intervals=new List<Vector2>();foreach(var region in Regions)if(Clip(region.bounds,from,to,out float low,out float high))intervals.Add(new Vector2(low,high));
            intervals.Sort((a,b)=>a.x.CompareTo(b.x));float covered=0;
            foreach(var span in intervals){if(span.x>covered+.000001f)return false;covered=Mathf.Max(covered,span.y);}
            if(covered<.999999f)return false;
            // Touching a blocker edge is permitted by server centre-line
            // semantics. Native actor clearance remains deliberately stricter.
            if(Clip(Bed,from,to,out float enter,out float exit)&&exit-enter>.000001f)
            {
                var midpoint=Vector3.Lerp(from,to,(enter+exit)*.5f);if(Interior(Bed,midpoint))return false;
            }
            return true;
        }
        private static bool Clip(WorldMapPlayableBounds b,Vector3 a,Vector3 c,out float low,out float high)
        {low=0;high=1;return Slab(a.x,c.x-a.x,b.minX,b.maxX,ref low,ref high)&&Slab(a.z,c.z-a.z,b.minZ,b.maxZ,ref low,ref high);}
        private static bool Slab(float origin,float delta,float min,float max,ref float low,ref float high)
        {if(Mathf.Abs(delta)<1e-8f)return origin>=min&&origin<=max;float a=(min-origin)/delta,b=(max-origin)/delta;if(a>b)(a,b)=(b,a);low=Mathf.Max(low,a);high=Mathf.Min(high,b);return low<=high;}
        private static bool Interior(WorldMapPlayableBounds b,Vector3 p)=>p.x>b.minX+.000001f&&p.x<b.maxX-.000001f&&p.z>b.minZ+.000001f&&p.z<b.maxZ-.000001f;
        public static PersonalSpaceNavigation FindNavigation(PersistentWorldMapController map)
        {
            var all=map?.PersistentEnvironmentRoot?.GetComponentsInChildren<PersonalSpaceNavigation>(true);
            return all?.Length==1&&ValidateNavigation(all[0])?all[0]:null;
        }
        public static bool ValidateNavigation(PersonalSpaceNavigation nav)
        {
            if(nav==null||nav.LayoutRevision!=LayoutRevision||nav.LayoutDigest!=LayoutDigest||
                string.IsNullOrWhiteSpace(nav.Revision)||nav.WalkableRegions?.Length!=3||nav.BedroomDoor==null||!nav.BedroomDoor.Ready)return false;
            var regions=Regions;
            for(int i=0;i<3;i++){var b=nav.WalkableRegions[i];if(!Near(b.min.x,regions[i].bounds.minX)||!Near(b.max.x,regions[i].bounds.maxX)||!Near(b.min.z,regions[i].bounds.minZ)||!Near(b.max.z,regions[i].bounds.maxZ))return false;}
            return Exact(Bed,nav.ContractBedBounds);
        }
        public static string ComputeDigest(){using var hash=SHA256.Create();return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(CanonicalUtf8))).Replace("-","").ToLowerInvariant();}
        public static bool Exact(WorldMapPlayableBounds expected,WorldMapPlayableBounds actual)=>actual!=null&&actual.IsValid&&Near(expected.minX,actual.minX)&&Near(expected.maxX,actual.maxX)&&Near(expected.minZ,actual.minZ)&&Near(expected.maxZ,actual.maxZ);
        private static bool Near(float a,float b)=>Finite(a)&&Finite(b)&&Mathf.Abs(a-b)<.0001f;
        public static bool Finite(float value)=>!float.IsNaN(value)&&!float.IsInfinity(value);
    }
}
