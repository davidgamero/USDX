import concurrent.futures
import ctypes
import sys
import unittest
from unittest.mock import patch

import scheduling


class SchedulingTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'macOS QoS API')
    def test_real_worker_thread_priority_and_restoration(self):
        def check():
            library = scheduling.darwin_qos()

            def current():
                qos, relative = ctypes.c_uint(), ctypes.c_int()
                result = library.pthread_get_qos_class_np(library.pthread_self(), ctypes.byref(qos), ctypes.byref(relative))
                self.assertEqual(result, 0)
                return qos.value

            before = current()
            with scheduling.user_initiated_priority():
                self.assertEqual(current(), scheduling.QOS_USER_INITIATED)
            self.assertEqual(current(), before or scheduling.QOS_UTILITY)
            with self.assertRaisesRegex(ValueError, 'job failed'):
                with scheduling.user_initiated_priority():
                    self.assertEqual(current(), scheduling.QOS_USER_INITIATED)
                    raise ValueError('job failed')
            self.assertEqual(current(), before or scheduling.QOS_UTILITY)

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            pool.submit(check).result()

    def test_unavailable_api_does_not_stop_conversion(self):
        with patch('scheduling.sys.platform', 'darwin'), patch('scheduling.darwin_qos', side_effect=OSError('unavailable')):
            with self.assertLogs(scheduling.LOG, level='WARNING'):
                with scheduling.user_initiated_priority():
                    entered = True
        self.assertTrue(entered)

    def test_non_macos_uses_normal_scheduler(self):
        with patch('scheduling.sys.platform', 'linux'), patch('scheduling.darwin_qos') as api:
            with scheduling.user_initiated_priority():
                pass
            api.assert_not_called()


if __name__ == '__main__':
    unittest.main()
