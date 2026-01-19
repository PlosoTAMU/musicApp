//
//  Python-Bridging-Header.h
//  musicApp
//
//  Bridging header for Python.xcframework
//  This enables calling Python C API from Swift
//

#ifndef Python_Bridging_Header_h
#define Python_Bridging_Header_h

// Only include Python.h if the framework is available
#if __has_include(<Python.h>)
#include <Python.h>
#endif

#endif /* Python_Bridging_Header_h */
