import 'mesh_transport_service_base.dart';
import 'mesh_transport_service_stub.dart'
    if (dart.library.io) 'mesh_transport_service_io.dart'
    as impl;

class MeshTransportService {
  MeshTransportService._();

  static final MeshTransportServiceBase instance = impl
      .createMeshTransportService();
}
