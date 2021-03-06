#cython: profile=True
# #cython: boundscheck=False
# #cython: wraparound=False
# #cython: nonecheck=False
#from __future__ import division
import numpy as np
import cython
cimport numpy as np
from libc.stdlib cimport malloc, free
from libcpp.unordered_set cimport unordered_set
#from libcpp.set cimport set
from libcpp.vector cimport vector
from cython.parallel cimport prange, threadid
from scipy.spatial import qhull
#import matplotlib.path as mplPath

# integer indices
DTYPE_int = np.int32
ctypedef np.int32_t DTYPE_int_t
# array values
DTYPE_flt = np.float64
ctypedef np.float64_t DTYPE_flt_t

# what type should things be?
# http://stackoverflow.com/questions/18462785/what-is-the-recommended-way-of-allocating-memory-for-a-typed-memory-view
# answer: malloc

# special value for border points
cdef DTYPE_int_t INT_NOT_FOUND = -9999

cdef class HexArray:
    # array shape
    cdef readonly DTYPE_int_t Nx, Ny, N
    cdef readonly bint index_right, has_data
    # raveled array data
    cdef DTYPE_flt_t [:] ar

    def __init__(self, np.ndarray[DTYPE_flt_t, ndim=2] data=None,
                        shape=None, idx_right=1):
        """Initialize new hex array of a given shape."""

        if (data is None and shape is None) or (data is None and shape is None):
            raise ValueError('Either data or shape must be specified')
        elif data is not None:
            if data.ndim != 2:
                raise ValueError('Only 2D data is allowed')
            self.Nx = data.shape[1]
            self.Ny = data.shape[0]
            self.ar = data.ravel()
            self.has_data = True
        else:
            if len(shape) != 2:
                raise ValueError('Shape muse be 2D')
            self.Nx = shape[1]
            self.Ny = shape[0]
            self.has_data = False
        self.N = self.Nx*self.Ny
        self.index_right = idx_right

    # this function sucks because it uses a python type (tuple)
    # and thus can't release the gil
    # using a c data structure (e.g. struct) would overcome gil limitation
    cpdef tuple ji_from_n(self, DTYPE_int_t n):
        cdef DTYPE_int_t j, i
        cdef tuple coord
        j = n / self.Nx
        i = n % self.Nx
        coord = (j, i)
        return coord

    cdef DTYPE_int_t n_from_ji(self, DTYPE_int_t j, DTYPE_int_t i) nogil:
        cdef DTYPE_int_t n
        n = i + j*self.Nx
        return n

    def N_from_ji(self, j, i):
        return self.n_from_ji(j, i)

    cdef bint is_border_n(self, DTYPE_int_t n) nogil:
        cdef DTYPE_int_t j, i
        j = n / self.Nx
        i = n % self.Nx
        return self.is_border_ji(j, i)

    cdef bint is_border_ji(self, DTYPE_int_t j, DTYPE_int_t i) nogil:
        return (i==0) or (i==self.Nx-1) or (j==0) or (j==self.Ny-1)

    cdef DTYPE_flt_t _xpos(self, int n) nogil:
        return <DTYPE_flt_t> (n % self.Nx) + 0.25 - 0.5*((n / self.Nx)%2)

    cdef DTYPE_flt_t _ypos(self, int n) nogil:
        return <DTYPE_flt_t> (n / self.Nx)

    def pos(self, int n):
        return (self._xpos(n), self._ypos(n))

    cdef int* _neighbors(self, DTYPE_int_t n) nogil:
        """Given index n, return neighbor indices.

        PARAMETERS
        ----------
        n : int
            1D index of point

        RETURNS
        -------
        nbr : int*
            pointer to array of 6 neighbor indices. Must be freed manually?
        """

        cdef DTYPE_int_t j, i
        cdef bint evenrow
        cdef int* nbr
        nbr = <int*> malloc(sizeof(int) * 6)
        nbr[0] = INT_NOT_FOUND

        j = n / self.Nx
        i = n % self.Nx
        evenrow = j % 2

        # don't even bother with border points
        if self.is_border_ji(j, i):
            return nbr

        if not evenrow:
            nbr[0] = self.n_from_ji(j-1, i)
            nbr[1] = self.n_from_ji(j-1, i+1)
            nbr[2] = self.n_from_ji(j, i+1)
            nbr[3] = self.n_from_ji(j+1, i+1)
            nbr[4] = self.n_from_ji(j+1, i)
            nbr[5] = self.n_from_ji(j, i-1)
        else:
            nbr[0] = self.n_from_ji(j-1, i-1)
            nbr[1] = self.n_from_ji(j-1, i)
            nbr[2] = self.n_from_ji(j, i+1)
            nbr[3] = self.n_from_ji(j+1, i)
            nbr[4] = self.n_from_ji(j+1, i-1)
            nbr[5] = self.n_from_ji(j, i-1)
        return nbr

    cdef DTYPE_int_t _classify_point(self, int n) nogil:
        cdef int k, kprev
        # neighbor pointer
        cdef int* nbr
        # raw difference
        cdef DTYPE_flt_t diff, diff_p
        # sign of differences
        cdef DTYPE_int_t sign_diff, sign_diff_p
        cdef DTYPE_int_t sum_sign_diff = 0

        if self.is_border_n(n):
            return 0
        else:
            nbr = self._neighbors(n)
            # fill in the differnces
            for k in range(6):
                kprev = (k-1) % 6
                diff = self.ar[n] - self.ar[nbr[k]]
                diff_p = self.ar[n] - self.ar[nbr[kprev]]
                # check for zero gradient
                if (diff==0.0) or (diff_p==0.0):
                    sum_sign_diff = -2
                    break
                if diff>0.0:
                    sign_diff = 1
                else:
                    sign_diff = -1
                if diff_p>0.0:
                    sign_diff_p = 1
                else:
                    sign_diff_p = -1
                sum_sign_diff += <DTYPE_int_t> (sign_diff != sign_diff_p)
            free(nbr)

            # regular point
            if sum_sign_diff==2:
                return 0
            # extremum
            elif sum_sign_diff==0:
                return sign_diff
            # saddle
            elif sum_sign_diff==4:
                return 2
            # zero gradient point
            elif sum_sign_diff==-2:
                return -2
            # something weird happened
            else:
                return -3


    def neighbors(self, n):
        """Given index n, return neighbor indices.

        PARAMETERS
        ----------
        n : int
            1D index of point

        RETURNS
        -------
        nbr : arraylike
            Numpy ndarray of neighbor points
        """
        cdef int * nptr = self._neighbors(n)
        cdef int [:] nbr
        if nptr[0] == INT_NOT_FOUND:
            free(nptr)
            return np.array([], DTYPE_int)
        else:
            nbr = <int[:6]> nptr
            numpy_array = np.asarray(nbr.copy())
            free(nptr)
            return numpy_array

    def classify_critical_points(self):
        """Identify and classify the critical points of data array.
        0: regular point
        +1: maximum
        -1: minimum
        +2: saddle point
        -2: zero gradient detected
        -3: monkey point

        RETURNS
        -------
        c : arraylike
            array with the same shape as a, with critical points marked
        """

        if not self.has_data:
            raise ValueError('HexArray was not initialized with data.')

        cdef DTYPE_int_t [:] c
        c = np.zeros(self.N, DTYPE_int)

        # loop index
        cdef int n

        for n in range(self.N):
            c[n] = self._classify_point(n)
        res = np.asarray(c).reshape(self.Ny, self.Nx)
        return res

    cpdef np.ndarray[int, ndim=1] maxima(self):
        cpoints = self.classify_critical_points()
        return np.nonzero(cpoints.ravel()==1)[0].astype(DTYPE_int)

cdef class HexArrayRegion:

    # the parent region
    cdef HexArray ha
    # the points in the region
    cdef unordered_set[int] members
    cdef vector[int] members_ordered
    cdef int first_point

    def __cinit__(self, HexArray ha, int first_pt = INT_NOT_FOUND):
        self.ha = ha
        if first_pt != INT_NOT_FOUND:
            self._add_point(first_pt)
        self.first_point = first_pt

    property members:
        def __get__(self):
            return self.members

    property first_point:
        def __get__(self):
            if self.first_point == INT_NOT_FOUND:
                return None
            else:
                return self.first_point

    def __contains__(self, int pt):
        return self.members.count(pt) > 0

    def add_point(self, int pt):
        self._add_point(pt)

    cdef void _add_point(self, int pt) nogil:
        self.members.insert(pt)

    def remove_point(self, int pt):
        self._remove_point(pt)

    cdef void _remove_point(self, int pt) nogil:
        self.members.erase(pt)

    def exterior_boundary(self):
        return self._exterior_boundary()

    cdef unordered_set[int] _exterior_boundary(self) nogil:
        cdef unordered_set[int] boundary
        cdef int n, k
        cdef int* nbr
        cdef int npt
        cdef size_t cnt
        for n in self.members:
            nbr = self.ha._neighbors(n)
            if not nbr[0] == INT_NOT_FOUND:
                for k in range(6):
                    cnt = self.members.count(nbr[k])
                    if cnt==0:
                        boundary.insert(nbr[k])
            free(nbr)
        return boundary

    def interior_boundary(self):
        return self._interior_boundary()

    cdef unordered_set[int] _interior_boundary(self) nogil:
        cdef unordered_set[int] boundary
        cdef int n
        for n in self.members:
            if self._is_boundary(n):
                boundary.insert(n)
        return boundary

    cdef bint _is_boundary(self, int n) nogil:
        cdef int* nbr
        cdef size_t cnt, k
        cdef bint result = 0
        nbr = self.ha._neighbors(n)
        cnt = 0
        if not nbr[0] == INT_NOT_FOUND:
            for k in range(6):
                cnt += self.members.count(nbr[k])
            if (cnt<6) and (cnt>0):
                result = 1
        free(nbr)
        return result

    def interior_boundary_ordered(self):
        return self._interior_boundary_ordered()

    cdef vector[int] _interior_boundary_ordered(self) nogil:
        cdef vector[int] boundary
        cdef int* nbr
        cdef int n, initpt, startpt, prevpt
        cdef bint looking = 1
        cdef size_t cnt=0,
        cdef size_t cntmax=100
        # first just find any point on the boundary
        for n in self.members:
            if self._is_boundary(n):
                boundary.push_back(n)
                initpt = n
                break
        # now iterate through neighbors, looking for other boundary points

        startpt = initpt
        prevpt = initpt
        cnt = 0
        while looking==1:
            # get the neighbors of the most recently added point
            looking = 0
            nbr = self.ha._neighbors(startpt)
            if nbr[0] == INT_NOT_FOUND:
                # we are on a boundary, stop iterating
                pass
            else:
                for n in range(6):
                    # check to see if neighbor point is also on boundary
                    if self.members.count(nbr[n])==1:
                        if self._is_boundary(nbr[n]):
                            if ((nbr[n] != startpt) and
                                (nbr[n] != prevpt) and
                                (nbr[n] != initpt)):
                                # stop iterating once we have found a good point
                                #print 'from', startpt, 'adding', nbr[n]
                                boundary.push_back(nbr[n])
                                prevpt = startpt
                                startpt = nbr[n]
                                looking = 1
                                break
                            else:
                                # if we got here, the circle is closed
                                pass
            free(nbr)
            cnt += 1
            #if cnt>cntmax:
            #    break
        return boundary

    def is_convex(self):
        return self._is_convex()

    @cython.linetrace(True)
    cdef bint _is_convex(self) nogil:
        # interior boundary
        cdef unordered_set[int] ib = self._interior_boundary()
        cdef unordered_set[int] eb = self._exterior_boundary()
        cdef DTYPE_flt_t [:,:] ib_points
        cdef size_t nib = ib.size()
        # the coordinates of the test point
        cdef DTYPE_flt_t xpt, ypt
        # the coordinates of the boundary points
        # need to pass a numpy array to qhull anyway
        #cdef np.ndarray[DTYPE_flt_t, ndim=2] ib_points

        # vertices of hull
        cdef DTYPE_flt_t [:,:] hull_vertices
        # worth making a view? how to release gil?

        cdef size_t npt, nhull, Nverts
        cdef int n = 0


        # straight python from here on
        # how to speed this up?
        with gil:
            ib_points = np.empty((nib, 2), dtype=DTYPE_flt)
        for npt in ib:
            ib_points[n,0] = self.ha._xpos(npt)
            ib_points[n,1] = self.ha._ypos(npt)
            n += 1

        # can't do try without gil
        #try:
        #    hull_vertices = _get_qhull_verts(ib_points)
        #except:
        #    return False
        with gil:
            hull_vertices = _get_qhull_verts(ib_points)
        if hull_vertices.shape[0]==0:
            return False

        # check to see if any of the exterior boundary points lie
        # inside the convex hull
        #with nogil:
        for npt in eb:
            xpt = self.ha._xpos(npt)
            ypt = self.ha._ypos(npt)
            if _point_in_poly(hull_vertices, xpt, ypt):
            #if _mpl_point_in_poly(hull_vertices, xpt, ypt):
                return False
        return True

    def still_convex(self, int pt):
        return self._still_convex(pt)

    cdef bint _still_convex(self, int pt):
        cdef bint sc
        self._add_point(pt)
        sc = self._is_convex()
        self._remove_point(pt)
        return sc


def find_convex_regions(np.ndarray[DTYPE_flt_t, ndim=2] a, int minsize=0,
                        return_labeled_array=False):
    """Find convex regions around the extrema of ``a``.

    PARAMETERS
    ----------
    a : arraylike
        The 2D field in which to search for convex regions. Must be dtype=f64.
    minsize : int
        The minimum size of regions to return (number of points)

    RETURNS
    -------
    regions : list of HexArrayRegion elements
    """

    cdef HexArray ha = HexArray(a)
    cdef DTYPE_int_t [:] maxima = ha.maxima()
    cdef DTYPE_int_t nmax
    # these are local to the loop
    cdef HexArrayRegion hr
    cdef unordered_set[int] bndry
    cdef int cnt, pt, next_pt
    cdef DTYPE_flt_t diff, diff_min
    cdef bint first_pt, is_convex

    regions = []
    for nmax in maxima:
        hr = HexArrayRegion(ha, nmax)
        #ordered_points = [nmax,]
        cnt = 0
        diff_min = 0.0
        is_convex = True
        while is_convex:
            bndry = hr._exterior_boundary()
            first_pt = True
            for pt in bndry:
                diff = ha.ar[nmax] - ha.ar[pt]
                if first_pt:
                    diff_min = diff
                    first_pt = False
                if diff <= diff_min:
                    next_pt = pt
                    diff_min = diff
            # at the begnning, just add the point
            if cnt < 3:
                hr._add_point(next_pt)
                #ordered_points.append(next_pt)
                cnt += 1
            # otherwise check for convexity
            else:
                if hr._still_convex(next_pt):
                    hr._add_point(next_pt)
                    #ordered_points.append(next_pt)
                else:
                    is_convex = False
        if hr.members.size() > minsize:
            #regions.append((hr, ordered_points))
            regions.append(hr)

    if return_labeled_array:
        return label_regions(regions, ha)
    else:
        return regions

def label_regions(regions, ha):
    r = np.full(ha.N, -1)
    for reg in regions:
        r[list(reg.members)] = reg.first_point
    r.shape = ha.Ny, ha.Nx
    return r

cdef bint _test_convex(HexArrayRegion hr, int pt):
    cdef unordered_set[int] ib = hr.interior_boundary()
    return 1

def point_in_poly(np.ndarray[DTYPE_flt_t, ndim=2] npverts,
                    DTYPE_flt_t testx, DTYPE_flt_t testy):
    cdef DTYPE_flt_t [:,:] verts
    verts = npverts
    return _point_in_poly(verts, testx, testy)

def mpl_point_in_poly(np.ndarray[DTYPE_flt_t, ndim=2] npverts,
                    DTYPE_flt_t testx, DTYPE_flt_t testy):
    cdef DTYPE_flt_t [:,:] verts
    verts = npverts
    return _mpl_point_in_poly(verts, testx, testy)

# I don't fully understand why this works, but it does
# http://stackoverflow.com/a/2922778/3266235
cdef bint _point_in_poly(DTYPE_flt_t [:,:] verts,
                         DTYPE_flt_t testx, DTYPE_flt_t testy) nogil:
    cdef size_t nvert = verts.shape[0]
    cdef size_t i = 0
    cdef size_t j = nvert -1
    cdef bint c = 0
    while (i < nvert):
        # apparently all I had to do was change the > to >= to make this
        # agree with matplotlib
        # if ( ((verts[i,1]>testy) != (verts[j,1]>testy)) and
        #      (testx < (verts[j,0]-verts[i,0]) * (testy-verts[i,1])
        #               / (verts[j,1]-verts[i,1]) + verts[i,0]) ):
        if ( ((verts[i,1]>=testy) != (verts[j,1]>=testy)) and
             (testx <= (verts[j,0]-verts[i,0]) * (testy-verts[i,1])
                      / (verts[j,1]-verts[i,1]) + verts[i,0]) ):

            c = not c
        j = i
        i += 1
    return c


# don't want to have to rely on matplotlib
#@cython.wraparound(True)
@cython.linetrace(True)
cdef bint _mpl_point_in_poly(DTYPE_flt_t [:,:] verts,
                         DTYPE_flt_t testx, DTYPE_flt_t testy):
    return 0
    # make sure polygon is closed
    # do outside function
    ##vertices = np.vstack([vertices, vertices[0]])
    # cdef np.ndarray[DTYPE_int_t, ndim=1] codes
    # cdef size_t Nverts = len(verts)
    # codes = np.full(Nverts, mplPath.Path.LINETO, dtype=DTYPE_int)
    # codes[0] = mplPath.Path.MOVETO
    # codes[Nverts-1] = mplPath.Path.CLOSEPOLY
    # bbPath = mplPath.Path(verts, codes)
    # return bbPath.contains_point((testx, testy), radius=0.0)

def get_qhull_verts(np.ndarray[DTYPE_flt_t, ndim=2] points):
    return np.asarray(_get_qhull_verts(points))

cdef DTYPE_flt_t [:,:] _get_qhull_verts(DTYPE_flt_t [:,:] points) nogil:
    cdef DTYPE_flt_t [:,:] hull_vertices, vert_pts
    cdef DTYPE_int_t [:] vert_idx
    cdef size_t Nverts, n
    with gil:
        try:
            hull = qhull.ConvexHull(points)
            Nverts = len(hull.vertices)
            hull_vertices = np.empty((Nverts+1,2), hull.points.dtype)
            vert_idx = hull.vertices
            vert_pts = hull.points
            hull_vertices[Nverts,0] = vert_pts[vert_idx[0],0]
            hull_vertices[Nverts,1] = vert_pts[vert_idx[0],1]
        except:
            return np.empty((0,2), DTYPE_flt)
        #Nverts = 0

    #hull_vertices = hull.points[hull.vertices]
    for n in range(Nverts):
        hull_vertices[n,0] = vert_pts[vert_idx[n],0]
        hull_vertices[n,1] = vert_pts[vert_idx[n],1]
    return hull_vertices

# cdef int pnpoly(int nvert, float vertx*, float verty*,
#                 float testx*, float testy*):
#     int i, j, c = 0
#     for (i = 0, j = nvert-1; i < nvert; j = i++) {
#       if ( ((verty[i]>testy) != (verty[j]>testy)) &&
#        (testx < (vertx[j]-vertx[i]) * (testy-verty[i]) / (verty[j]-verty[i]) + vertx[i]) )
#          c = !c;
#     }
#     return c;
#   }
