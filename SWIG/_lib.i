/* Copyright (c) 1999-2004 Ng Pheng Siong. All rights reserved. */
/* $Id$ */

%{
#include <openssl/dh.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509_vfy.h>
#include <ceval.h>

/* OpenSSL 1.1 compatibility shim */
#include "libcrypto-compat.c"

/* OpenSSL 1.0.2 copmatbility shim */
#if OPENSSL_VERSION_NUMBER < 0x10002000L
typedef void (*OPENSSL_sk_freefunc)(void *);
typedef void *(*OPENSSL_sk_copyfunc)(const void *);
typedef struct stack_st OPENSSL_STACK;

# define MIN_NODES       4
# define sk_deep_copy OPENSSL_sk_deep_copy

void OPENSSL_sk_free(OPENSSL_STACK *st)
{
    if (st == NULL)
        return;
    OPENSSL_free(st->data);
    OPENSSL_free(st);
}

OPENSSL_STACK *OPENSSL_sk_deep_copy(const OPENSSL_STACK *sk,
                             OPENSSL_sk_copyfunc copy_func,
                             OPENSSL_sk_freefunc free_func)
{
    OPENSSL_STACK *ret;
    int i;

    if (sk->num < 0)
        return NULL;

    if ((ret = OPENSSL_malloc(sizeof(*ret))) == NULL)
        return NULL;

    /* direct structure assignment */
    *ret = *sk;

    ret->num_alloc = sk->num > MIN_NODES ? (size_t)sk->num : MIN_NODES;
    ret->data = OPENSSL_zalloc(sizeof(*ret->data) * ret->num_alloc);
    if (ret->data == NULL) {
        OPENSSL_free(ret);
        return NULL;
    }

    for (i = 0; i < ret->num; ++i) {
        if (sk->data[i] == NULL)
            continue;
        if ((ret->data[i] = copy_func(sk->data[i])) == NULL) {
            while (--i >= 0)
                if (ret->data[i] != NULL)
                    free_func((void *)ret->data[i]);
            OPENSSL_sk_free(ret);
            return NULL;
        }
    }
    return ret;
}
#endif /* OpenSSL 1.0.2 copmatbility shim */


/* Blob interface. Deprecated. */

Blob *blob_new(int len, const char *errmsg) {

    Blob *blob;
    if (!(blob=(Blob *)PyMem_Malloc(sizeof(Blob)))){
        PyErr_SetString(PyExc_MemoryError, errmsg);
        return NULL;
    }
    if (!(blob->data=(unsigned char *)PyMem_Malloc(len))) {
        PyMem_Free(blob);
        PyErr_SetString(PyExc_MemoryError, errmsg);
        return NULL;
    }
    blob->len=len;
    return blob;
}

Blob *blob_copy(Blob *from, const char *errmsg) {
    Blob *blob=blob_new(from->len, errmsg);
    if (!blob) {
        PyErr_SetString(PyExc_MemoryError, errmsg);
        return NULL;
    }
    memcpy(blob->data, from->data, from->len);
    return blob;
}

void blob_free(Blob *blob) {
    PyMem_Free(blob->data);
    PyMem_Free(blob);
}


/* Python helpers. */

%}
%ignore PyObject_CheckBuffer;
%ignore PyObject_GetBuffer;
%ignore PyBuffer_Release;
%ignore m2_PyObject_AsReadBufferInt;
%ignore m2_PyObject_GetBufferInt;
%ignore m2_PyBuffer_Release;
%ignore m2_PyString_AsStringAndSizeInt;
%{

static int
m2_PyObject_AsReadBufferInt(PyObject *obj, const void **buffer,
                int *buffer_len)
{
    int ret;
    Py_ssize_t len;

    ret = PyObject_AsReadBuffer(obj, buffer, &len);
    if (ret)
        return ret;
    if (len > INT_MAX) {
        PyErr_SetString(PyExc_ValueError, "object too large");
        return -1;
    }
    *buffer_len = len;
    return 0;
}

static int m2_PyObject_GetBufferInt(PyObject *obj, Py_buffer *view, int flags)
{
    int ret;

    if (PyObject_CheckBuffer(obj))
	ret = PyObject_GetBuffer(obj, view, flags);
    else {
	const void *buf;

	ret = PyObject_AsReadBuffer(obj, &buf, &view->len);
	if (ret == 0)
	    view->buf = (void *)buf;
    }
    if (ret)
	return ret;
    if (view->len > INT_MAX) {
	PyErr_SetString(PyExc_ValueError, "object too large");
	m2_PyBuffer_Release(obj, view);
	return -1;
    }

    return 0;
}

static BIGNUM*
m2_PyObject_AsBIGNUM(PyObject* value, PyObject* _py_exc)
{
    BIGNUM* bn;
    const void* vbuf;
    int vlen;

    if (m2_PyObject_AsReadBufferInt(value, &vbuf, &vlen) == -1)
        return NULL;

    if (!(bn = BN_mpi2bn((unsigned char *)vbuf, vlen, NULL))) {
        PyErr_SetString(_py_exc, ERR_reason_error_string(ERR_get_error()));
        return NULL;
        }

    return bn;
}

static void m2_PyBuffer_Release(PyObject *obj, Py_buffer *view)
{
    if (PyObject_CheckBuffer(obj))
	PyBuffer_Release(view);
    /* else do nothing, view->buf comes from PyObject_AsReadBuffer */
}

static int
m2_PyString_AsStringAndSizeInt(PyObject *obj, char **s, int *len)
{
    int ret;
    Py_ssize_t len2;

#if PY_MAJOR_VERSION >= 3
    ret = PyBytes_AsStringAndSize(obj, s, &len2);
#else
    ret = PyString_AsStringAndSize(obj, s, &len2);
#endif // PY_MAJOR_VERSION >= 3

    if (ret)
       return ret;
    if (len2 > INT_MAX) {
       PyErr_SetString(PyExc_ValueError, "string too large");
       return -1;
    }
    *len = len2;
    return 0;
}


/* C callbacks invoked by OpenSSL; these in turn call back into
Python. */

int ssl_verify_callback(int ok, X509_STORE_CTX *ctx) {
    PyObject *argv, *ret;
    PyObject *_x509_store_ctx_swigptr=0, *_x509_store_ctx_obj=0, *_x509_store_ctx_inst=0, *_klass=0;
    PyObject *_x509=0, *_ssl_ctx=0;
    SSL *ssl;
    SSL_CTX *ssl_ctx;
    X509 *x509;
    int errnum, errdepth;
    int cret;
    int new_style_callback = 0, warning_raised_exception=0;
    PyGILState_STATE gilstate;
    PyObject *self = NULL; /* bug in SWIG_NewPointerObj as of 3.0.5 */

    ssl = (SSL *)X509_STORE_CTX_get_app_data(ctx);

    gilstate = PyGILState_Ensure();

    if (PyMethod_Check(ssl_verify_cb_func)) {
        PyObject *func;
        PyCodeObject *code;
        func = PyMethod_Function(ssl_verify_cb_func);
        code = (PyCodeObject *) PyFunction_GetCode(func);
        if (code && code->co_argcount == 3) { /* XXX Python internals */
            new_style_callback = 1;
        }
    } else if (PyFunction_Check(ssl_verify_cb_func)) {
        PyCodeObject *code = (PyCodeObject *) PyFunction_GetCode(ssl_verify_cb_func);
        if (code && code->co_argcount == 2) { /* XXX Python internals */
            new_style_callback = 1;
        }
    } else {
        /* XXX There are lots of other callable types, but we will assume
         * XXX that any other type of callable uses the new style callback,
         * XXX although this is not entirely safe assumption.
         */
        new_style_callback = 1;
    }

    if (new_style_callback) {
        PyObject *x509mod = PyDict_GetItemString(PyImport_GetModuleDict(), "M2Crypto.X509");
        _klass = PyObject_GetAttrString(x509mod, "X509_Store_Context");

        _x509_store_ctx_swigptr = SWIG_NewPointerObj((void *)ctx, SWIGTYPE_p_X509_STORE_CTX, 0);
        _x509_store_ctx_obj = Py_BuildValue("(Oi)", _x509_store_ctx_swigptr, 0);

#if PY_MAJOR_VERSION >= 3
        _x509_store_ctx_inst = PyType_GenericNew(_klass, _x509_store_ctx_obj, NULL);
#else
        _x509_store_ctx_inst = PyInstance_New(_klass, _x509_store_ctx_obj, NULL);
#endif // PY_MAJOR_VERSION >= 3

        argv = Py_BuildValue("(iO)", ok, _x509_store_ctx_inst);
    } else {
        if (PyErr_Warn(PyExc_DeprecationWarning, "Old style callback, use cb_func(ok, store) instead")) {
            warning_raised_exception = 1;
        }

        x509 = X509_STORE_CTX_get_current_cert(ctx);
        errnum = X509_STORE_CTX_get_error(ctx);
        errdepth = X509_STORE_CTX_get_error_depth(ctx);

        ssl = (SSL *)X509_STORE_CTX_get_app_data(ctx);
        ssl_ctx = SSL_get_SSL_CTX(ssl);

        _x509 = SWIG_NewPointerObj((void *)x509, SWIGTYPE_p_X509, 0);
        _ssl_ctx = SWIG_NewPointerObj((void *)ssl_ctx, SWIGTYPE_p_SSL_CTX, 0);
        argv = Py_BuildValue("(OOiii)", _ssl_ctx, _x509, errnum, errdepth, ok);
    }

    if (!warning_raised_exception) {
        ret = PyEval_CallObject(ssl_verify_cb_func, argv);
    } else {
        ret = 0;
    }

    if (!ret) {
        /* Got an exception in PyEval_CallObject(), let's fail verification
         * to be safe.
         */
        cret = 0;
    } else {
        cret = (int)PyInt_AsLong(ret);
    }
    Py_XDECREF(ret);
    Py_XDECREF(argv);
    if (new_style_callback) {
        Py_XDECREF(_x509_store_ctx_inst);
        Py_XDECREF(_x509_store_ctx_obj);
        Py_XDECREF(_x509_store_ctx_swigptr);
        Py_XDECREF(_klass);
    } else {
        Py_XDECREF(_x509);
        Py_XDECREF(_ssl_ctx);
    }

    PyGILState_Release(gilstate);

    return cret;
}

int x509_store_verify_callback(int ok, X509_STORE_CTX *ctx) {
    PyGILState_STATE gilstate;
    PyObject *argv, *ret;
    PyObject *_x509_store_ctx_swigptr=0, *_x509_store_ctx_obj=0, *_x509_store_ctx_inst=0, *_klass=0;
    int cret;
    PyObject *self = NULL; /* bug in SWIG_NewPointerObj as of 3.0.5 */


    gilstate = PyGILState_Ensure();

    /* Below, handle only what is called 'new style callback' in ssl_verify_callback().
       TODO: does 'old style callback' exist any more? */
    PyObject *x509mod = PyDict_GetItemString(PyImport_GetModuleDict(), "M2Crypto.X509");
    _klass = PyObject_GetAttrString(x509mod, "X509_Store_Context");
    _x509_store_ctx_swigptr = SWIG_NewPointerObj((void *)ctx, SWIGTYPE_p_X509_STORE_CTX, 0);
    _x509_store_ctx_obj = Py_BuildValue("(Oi)", _x509_store_ctx_swigptr, 0);

#if PY_MAJOR_VERSION >= 3
        _x509_store_ctx_inst = PyType_GenericNew(_klass, _x509_store_ctx_obj, NULL);
#else
        _x509_store_ctx_inst = PyInstance_New(_klass, _x509_store_ctx_obj, NULL);
#endif // PY_MAJOR_VERSION >= 3

    argv = Py_BuildValue("(iO)", ok, _x509_store_ctx_inst);

    ret = PyEval_CallObject(x509_store_verify_cb_func, argv);
    if (!ret) {
        /* Got an exception in PyEval_CallObject(), let's fail verification
         * to be safe.
         */
        cret = 0;
    } else {
        cret = (int)PyInt_AsLong(ret);
    }

    Py_XDECREF(ret);
    Py_XDECREF(argv);
    Py_XDECREF(_x509_store_ctx_inst);
    Py_XDECREF(_x509_store_ctx_obj);
    Py_XDECREF(_x509_store_ctx_swigptr);
    Py_XDECREF(_klass);

    PyGILState_Release(gilstate);
    return cret;
}

void ssl_info_callback(const SSL *s, int where, int ret) {
    PyObject *argv, *retval, *_SSL;
    PyGILState_STATE gilstate;
    PyObject *self = NULL; /* bug in SWIG_NewPointerObj as of 3.0.5 */

    gilstate = PyGILState_Ensure();

    _SSL = SWIG_NewPointerObj((void *)s, SWIGTYPE_p_SSL, 0);
    argv = Py_BuildValue("(iiO)", where, ret, _SSL);

    retval = PyEval_CallObject(ssl_info_cb_func, argv);

    Py_XDECREF(retval);
    Py_XDECREF(argv);
    Py_XDECREF(_SSL);

    PyGILState_Release(gilstate);
}

DH *ssl_set_tmp_dh_callback(SSL *ssl, int is_export, int keylength) {
    PyObject *argv, *ret, *_ssl;
    DH *dh;
    PyGILState_STATE gilstate;
    PyObject *self = NULL; /* bug in SWIG_NewPointerObj as of 3.0.5 */

    gilstate = PyGILState_Ensure();

    _ssl = SWIG_NewPointerObj((void *)ssl, SWIGTYPE_p_SSL, 0);
    argv = Py_BuildValue("(Oii)", _ssl, is_export, keylength);

    ret = PyEval_CallObject(ssl_set_tmp_dh_cb_func, argv);

    if ((SWIG_ConvertPtr(ret, (void **)&dh, SWIGTYPE_p_DH, SWIG_POINTER_EXCEPTION | 0)) == -1)
      dh = NULL;
    Py_XDECREF(ret);
    Py_XDECREF(argv);
    Py_XDECREF(_ssl);

    PyGILState_Release(gilstate);

    return dh;
}

RSA *ssl_set_tmp_rsa_callback(SSL *ssl, int is_export, int keylength) {
    PyObject *argv, *ret, *_ssl;
    RSA *rsa;
    PyGILState_STATE gilstate;
    PyObject *self = NULL; /* bug in SWIG_NewPointerObj as of 3.0.5 */

    gilstate = PyGILState_Ensure();

    _ssl = SWIG_NewPointerObj((void *)ssl, SWIGTYPE_p_SSL, 0);
    argv = Py_BuildValue("(Oii)", _ssl, is_export, keylength);

    ret = PyEval_CallObject(ssl_set_tmp_rsa_cb_func, argv);

    if ((SWIG_ConvertPtr(ret, (void **)&rsa, SWIGTYPE_p_RSA, SWIG_POINTER_EXCEPTION | 0)) == -1)
      rsa = NULL;
    Py_XDECREF(ret);
    Py_XDECREF(argv);
    Py_XDECREF(_ssl);

    PyGILState_Release(gilstate);

    return rsa;
}

void gen_callback(int p, int n, void *arg) {
    PyObject *argv, *ret, *cbfunc;

    PyGILState_STATE gilstate;
    gilstate = PyGILState_Ensure();
    cbfunc = (PyObject *)arg;
    argv = Py_BuildValue("(ii)", p, n);
    ret = PyEval_CallObject(cbfunc, argv);
    Py_DECREF(argv);
    Py_XDECREF(ret);
    PyGILState_Release(gilstate);
}

int passphrase_callback(char *buf, int num, int v, void *arg) {
    int i;
    Py_ssize_t len;
    char *str;
    PyObject *argv, *ret, *cbfunc;
    PyGILState_STATE gilstate;

    gilstate = PyGILState_Ensure();
    cbfunc = (PyObject *)arg;
    argv = Py_BuildValue("(i)", v);
    ret = PyEval_CallObject(cbfunc, argv);
    Py_DECREF(argv);
    if (ret == NULL) {
        PyGILState_Release(gilstate);
        return -1;
    }

#if PY_MAJOR_VERSION >= 3
    if (!PyBytes_Check(ret)) {
        Py_DECREF(ret);
        PyGILState_Release(gilstate);
        return -1;
    }
    if ((len = PyBytes_Size(ret)) > num)
        len = num;
    str = PyBytes_AsString(ret);
#else
    if (!PyString_Check(ret)) {
        Py_DECREF(ret);
        PyGILState_Release(gilstate);
        return -1;
    }
    if ((len = PyString_Size(ret)) > num)
        len = num;
    str = PyString_AsString(ret);
#endif // PY_MAJOR_VERSION >= 3

    for (i = 0; i < len; i++)
        buf[i] = str[i];
    Py_DECREF(ret);
    PyGILState_Release(gilstate);
    return len;
}
%}

%inline %{

void lib_init() {
#if OPENSSL_VERSION_NUMBER < 0x10100000L
    SSLeay_add_all_algorithms();
    ERR_load_ERR_strings();
#endif
}

/* Bignum routines that aren't not numerous enough to
warrant a separate file. */

PyObject *bn_to_mpi(BIGNUM *bn) {
    int len;
    unsigned char *mpi;
    PyObject *pyo;

    len = BN_bn2mpi(bn, NULL);
    if (!(mpi=(unsigned char *)PyMem_Malloc(len))) {
        PyErr_SetString(PyExc_RuntimeError,
            ERR_error_string(ERR_get_error(), NULL));
        return NULL;
    }
    len=BN_bn2mpi(bn, mpi);

#if PY_MAJOR_VERSION >= 3
    pyo=PyBytes_FromStringAndSize((const char *)mpi, len);
#else
    pyo=PyString_FromStringAndSize((const char *)mpi, len);
#endif // PY_MAJOR_VERSION >= 3

    PyMem_Free(mpi);
    return pyo;
}

const BIGNUM *mpi_to_bn(PyObject *value) {
    const void *vbuf;
    int vlen;

    if (m2_PyObject_AsReadBufferInt(value, &vbuf, &vlen) == -1)
        return NULL;

    return BN_mpi2bn(vbuf, vlen, NULL);
}

PyObject *bn_to_bin(BIGNUM *bn) {
    int len;
    unsigned char *bin;
    PyObject *pyo;

    len = BN_num_bytes(bn);
    if (!(bin=(unsigned char *)PyMem_Malloc(len))) {
      PyErr_SetString(PyExc_MemoryError, "bn_to_bin");
      return NULL;
    }
    BN_bn2bin(bn, bin);

#if PY_MAJOR_VERSION >= 3
    pyo=PyBytes_FromStringAndSize((const char *)bin, len);
#else
    pyo=PyString_FromStringAndSize((const char *)bin, len);
#endif // PY_MAJOR_VERSION >= 3

    PyMem_Free(bin);
    return pyo;
}

const BIGNUM *bin_to_bn(PyObject *value) {
    const void *vbuf;
    int vlen;

    if (m2_PyObject_AsReadBufferInt(value, &vbuf, &vlen) == -1)
        return NULL;

    return BN_bin2bn(vbuf, vlen, NULL);
}

PyObject *bn_to_hex(BIGNUM *bn) {
    char *hex;
    PyObject *pyo;
    Py_ssize_t len;

    hex = BN_bn2hex(bn);
    if (!hex) {
        PyErr_SetString(PyExc_RuntimeError,
              ERR_error_string(ERR_get_error(), NULL));
        OPENSSL_free(hex);
        return NULL;
    }
    len = strlen(hex);

#if PY_MAJOR_VERSION >= 3
    pyo=PyBytes_FromStringAndSize(hex, len);
#else
    pyo=PyString_FromStringAndSize(hex, len);
#endif // PY_MAJOR_VERSION >= 3

    OPENSSL_free(hex);
    return pyo;
}

const BIGNUM *hex_to_bn(PyObject *value) {
    const void *vbuf;
    Py_ssize_t vlen;
    BIGNUM *bn;

    if (PyObject_AsReadBuffer(value, &vbuf, &vlen) == -1)
        return NULL;

    if ((bn=BN_new())==NULL) {
        PyErr_SetString(PyExc_MemoryError, "hex_to_bn");
        return NULL;
    }
    if (BN_hex2bn(&bn, (const char *)vbuf) <= 0) {
        PyErr_SetString(PyExc_RuntimeError,
              ERR_error_string(ERR_get_error(), NULL));
        BN_free(bn);
        return NULL;
    }
    return bn;
}

const BIGNUM *dec_to_bn(PyObject *value) {
    const void *vbuf;
    Py_ssize_t vlen;
    BIGNUM *bn;

    if (PyObject_AsReadBuffer(value, &vbuf, &vlen) == -1)
        return NULL;

    if ((bn=BN_new())==NULL) {
      PyErr_SetString(PyExc_MemoryError, "dec_to_bn");
      return NULL;
    }
    if ((BN_dec2bn(&bn, (const char *)vbuf) <= 0)) {
      PyErr_SetString(PyExc_RuntimeError,
            ERR_error_string(ERR_get_error(), NULL));
      BN_free(bn);
      return NULL;
    }
    return bn;
}
%}


/* Various useful typemaps. */

%typemap(in) Blob * {
    Py_ssize_t len;

#if PY_MAJOR_VERSION >= 3
    if (!PyBytes_Check($input)) {
        PyErr_SetString(PyExc_TypeError, "expected PyString");
        return NULL;
    }
    len=PyBytes_Size($input);
#else
    if (!PyString_Check($input)) {
        PyErr_SetString(PyExc_TypeError, "expected PyString");
        return NULL;
    }
    len=PyString_Size($input);
#endif // PY_MAJOR_VERSION >= 3

    if (len > INT_MAX) {
        PyErr_SetString(PyExc_ValueError, "object too large");
        return -1;
    }
    $1=(Blob *)PyMem_Malloc(sizeof(Blob));
    if (!$1) {
        PyErr_SetString(PyExc_MemoryError, "malloc Blob");
        return NULL;
    }

#if PY_MAJOR_VERSION >= 3
    $1->data=(unsigned char *)PyBytes_AsString($input);
#else
    $1->data=(unsigned char *)PyString_AsString($input);
#endif // PY_MAJOR_VERSION >= 3

    $1->len=len;
}

%typemap(out) Blob * {
    if ($1==NULL) {
        Py_INCREF(Py_None);
        $result=Py_None;
    } else {

#if PY_MAJOR_VERSION >= 3
        $result=PyBytes_FromStringAndSize((const char *)$1->data, $1->len);
#else
        $result=PyString_FromStringAndSize((const char *)$1->data, $1->len);
#endif // PY_MAJOR_VERSION >= 3

        PyMem_Free($1->data);
        PyMem_Free($1);
    }
}

/*
PyFile* is not part of Python3 ... if we’ll ever need it, we have to
replace it completely.
http://stackoverflow.com/questions/8195383/pyfile-type-replaced-by

%typemap(in) FILE * {
#if PY_MAJOR_VERSION >= 3
    $1=PyObject_AsFileDescriptor($input);
#else
    if (!PyFile_Check($input)) {
        PyErr_SetString(PyExc_TypeError, "expected PyFile");
        return NULL;
    }
    $1=PyFile_AsFile($input);
#endif // PY_MAJOR_VERSION >= 3
}
*/

%typemap(in) PyObject *pyfunc {
    if (!PyCallable_Check($input)) {
        PyErr_SetString(PyExc_TypeError, "expected PyCallable");
        return NULL;
    }
    $1=$input;
}

%typemap(in) PyObject *pyblob {
#if PY_MAJOR_VERSION >= 3
    if (!PyBytes_Check($input)) {
#else
    if (!PyString_Check($input)) {
#endif // PY_MAJOR_VERSION >= 3

        PyErr_SetString(PyExc_TypeError, "expected PyString");
        return NULL;
    }
    $1=$input;
}

%typemap(in) PyObject * {
    $1=$input;
}

%typemap(out) PyObject * {
    $result=$1;
}

%typemap(out) int {
    $result=PyInt_FromLong($1);
    if (PyErr_Occurred()) SWIG_fail;
}

/* Pointer checks. */

%apply Pointer NONNULL { Blob * };


/* A bunch of "straight-thru" functions. */

%rename(err_print_errors) ERR_print_errors;
%threadallow ERR_print_errors;
extern void ERR_print_errors(BIO *);
%rename(err_get_error) ERR_get_error;
extern unsigned long ERR_get_error(void);
%rename(err_peek_error) ERR_peek_error;
extern unsigned long ERR_peek_error(void);
%rename(err_lib_error_string) ERR_lib_error_string;
extern const char *ERR_lib_error_string(unsigned long);
%rename(err_func_error_string) ERR_func_error_string;
extern const char *ERR_func_error_string(unsigned long);
%rename(err_reason_error_string) ERR_reason_error_string;
extern const char *ERR_reason_error_string(unsigned long);
