import importlib.util
import json
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('v4_contract',ROOT/'tool/blender/coastal_bedroom_v4/export_contract.py')
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)

class V4ExportContractTest(unittest.TestCase):
    def contract(self):
        layout=json.loads((ROOT/'docs/avatar/coastal_bedroom_v4/layout.json').read_text())
        bed=json.loads((ROOT/'docs/avatar/coastal_bedroom_v4/bed-metadata.json').read_text())
        return mod.make_contract(layout,bed)
    def test_l_shape_is_union_with_real_portal_not_full_bounding_box(self):
        regions=self.contract()['walkableRegions']
        for point in [(0,0),(-6,-2),(-4.1,-2.1)]:self.assertTrue(mod.contains_floor(regions,*point))
        for point in [(-6,2),(-4.1,0),(-4.1,-3),(-9,-2)]:self.assertFalse(mod.contains_floor(regions,*point))
    def test_bed_collider_and_anchor_axes_preserve_authored_height(self):
        c=self.contract();self.assertEqual(c['bedCollider']['boundsUnity'][::3],[5.45,7.65])
        self.assertEqual(c['mattressTopMetres'],.571)
        self.assertEqual(c['bedInteraction']['lie_center']['positionUnity'],[6.51,.65,2.1])
        self.assertIsInstance(c['bedContactReviewRequired'],bool)
    def test_two_doors_have_separate_pivots_and_correct_open_translation(self):
        c=self.contract();self.assertEqual(len(c['doors']),2)
        self.assertEqual(c['doors'][0]['openRotationEulerUnity'],[0,-100,0])
        a,b=c['doors'][1]['closedPositionUnity'],c['doors'][1]['openPositionUnity']
        self.assertAlmostEqual(b[2]-a[2],-1.04)
    def entry_attachments(self):
        return {
            'V4_EntryFrame': [-3.04,-4.02,0,-2.98,-3.93,2.38],
            'V4_EntryFrame.001': [-2.02,-4.02,0,-1.96,-3.93,2.38],
            'V4_EntryFrame_Top': [-3.04,-4.02,2.35,-1.96,-3.93,2.42],
            'V4_EntryInsideHandle': [-2.3,-3.99,1,-2.1,-3.94,1.2],
            'V4_EntryOutsideHandle': [-2.3,-4.1,1,-2.1,-4.05,1.2],
        }
    def test_closed_leaf_bounds_are_exact_and_converted_for_both_doors(self):
        entry,bedroom=self.contract()['doors']
        self.assertEqual(entry['closedLeafBoundsUnity'],[2.015,0,4.005,2.985,2.35,4.065])
        self.assertEqual(bedroom['closedLeafBoundsUnity'],[4.099,0,1.58,4.141,2.29,2.62])
        for door in (entry,bedroom):
            self.assertEqual(door['closedLeafBoundsUnity'],mod.unity_bounds(door['closedLeafBoundsBlender']))
    def test_evaluated_leaf_tolerance_and_double_parent_translation(self):
        entry=self.contract()['doors'][0];expected=entry['closedLeafBoundsBlender']
        mod.validate_door_geometry(entry,expected,self.entry_attachments())
        mod.validate_door_geometry(entry,[v+.0005 for v in expected],self.entry_attachments())
        for offset in [(-2.985,-4.035,0),(.002,0,0)]:
            actual=[v+offset[i%3] for i,v in enumerate(expected)]
            with self.assertRaises(ValueError):mod.validate_door_geometry(entry,actual,self.entry_attachments())
    def test_frames_and_handles_cannot_have_hidden_double_parent_offsets(self):
        entry=self.contract()['doors'][0]
        for name in self.entry_attachments():
            with self.subTest(name=name):
                parts=self.entry_attachments();parts[name]=[v+(-2.5,-4.035,0)[i%3] for i,v in enumerate(parts[name])]
                with self.assertRaises(ValueError):mod.validate_door_geometry(entry,entry['closedLeafBoundsBlender'],parts)
        parts=self.entry_attachments();parts.pop('V4_EntryInsideHandle')
        with self.assertRaises(ValueError):mod.validate_door_geometry(entry,entry['closedLeafBoundsBlender'],parts)
    def test_pocket_authored_open_and_exported_closed_poses_are_distinct(self):
        door=self.contract()['doors'][1];closed=door['closedLeafBoundsBlender'];offset=door['sourceAuthoredLeafOffsetBlender']
        opened=[v+offset[i%3] for i,v in enumerate(closed)]
        mod.validate_door_geometry(door,opened,source_pose=True)
        mod.validate_door_geometry(door,closed,source_pose=False)
        with self.assertRaises(ValueError):mod.validate_door_geometry(door,opened,source_pose=False)
        with self.assertRaises(ValueError):mod.validate_door_geometry(door,closed,source_pose=True)

    def test_locked_objects_and_fifty_bed_sources_are_retained(self):
        c=self.contract();self.assertEqual(len(c['lockedOriginalObjects']),150)
        self.assertEqual(len(set(c['bedSourceObjects'])),50)
        self.assertTrue(all(len(r['matrixBlender'])==16 for r in c['lockedOriginalObjects']))

if __name__=='__main__':unittest.main()
