"""Regression cases for the negative-origin dual-display failure in this project."""

import unittest

from tools.capture_screen import crop_to_image, parse_box


class CaptureCoordinatesTests(unittest.TestCase):
    def test_primary_monitor_is_shifted_by_left_portrait_display(self):
        self.assertEqual(crop_to_image((0, 0, 3840, 2160), "screen", (-1440, -178), (5280, 2560)), (1440, 178, 5280, 2338))

    def test_negative_top_and_left_offsets(self):
        self.assertEqual(crop_to_image((-1440, -400, 0, 2160), "screen", (-1440, -400), (5280, 2560)), (0, 0, 1440, 2560))

    def test_image_coordinates_are_not_shifted_twice(self):
        self.assertEqual(crop_to_image((3025, 215, 3525, 1665), "image", (-1440, 0), (5280, 2560)), (3025, 215, 3525, 1665))

    def test_out_of_bounds_or_empty_crops_fail_instead_of_padding(self):
        for box in [(-1, 0, 100, 100), (0, 0, 5281, 100), (0, 0, 100, 2561), (100, 0, 100, 100), (0, 100, 100, 10)]:
            with self.subTest(box=box), self.assertRaises(ValueError):
                crop_to_image(box, "image", (-1440, 0), (5280, 2560))

    def test_crop_parser_accepts_negative_screen_origin(self):
        self.assertEqual(parse_box("-1440,-400,0,2160"), (-1440, -400, 0, 2160))


if __name__ == "__main__":
    unittest.main()
