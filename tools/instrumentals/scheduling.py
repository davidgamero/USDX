"""Give conversions user-initiated QoS while their coordinating thread is busy."""

from contextlib import contextmanager
import ctypes
import logging
import sys

LOG = logging.getLogger("instrumentals")
PRIORITY_PROFILE = "user-initiated-v1"
QOS_USER_INITIATED = 0x19
QOS_UTILITY = 0x11


def darwin_qos():
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    library.pthread_self.restype = ctypes.c_void_p
    library.pthread_get_qos_class_np.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_int)]
    library.pthread_get_qos_class_np.restype = ctypes.c_int
    library.pthread_set_qos_class_self_np.argtypes = [ctypes.c_uint, ctypes.c_int]
    library.pthread_set_qos_class_self_np.restype = ctypes.c_int
    return library


@contextmanager
def user_initiated_priority():
    library = None
    previous = ctypes.c_uint(QOS_UTILITY)
    relative = ctypes.c_int(0)
    if sys.platform == "darwin":
        try:
            library = darwin_qos()
            result = library.pthread_get_qos_class_np(library.pthread_self(), ctypes.byref(previous), ctypes.byref(relative))
            if result != 0 or previous.value == 0:
                previous.value, relative.value = QOS_UTILITY, 0
            result = library.pthread_set_qos_class_self_np(QOS_USER_INITIATED, 0)
            if result != 0:
                raise OSError(result, "Could not set user-initiated QoS")
            LOG.info("Conversion QoS: user-initiated")
        except (OSError, AttributeError) as error:
            library = None
            LOG.warning("Could not raise conversion QoS: %s", error)
    try:
        yield
    finally:
        if library is not None:
            library.pthread_set_qos_class_self_np(previous.value, relative.value)
