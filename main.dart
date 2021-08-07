import 'dart:convert';
import 'dart:io' as io;

import 'package:googleapis/drive/v3.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

final String newEmail = "xxxx";

main() async {
  print("Initializing script.");

  final httpClient = await authenticate();

  await listRootFiles(httpClient);

  print('End script');
}

Future<http.Client> authenticate() async {
  print('Authenticating');
  http.Client? httpClient;

  final logger = Logger();
  var file = json.decode(await io.File('credentials.json').readAsString());

  final clientId = ClientId(file['web']['client_id'], file['web']['client_secret']);

  final scopes = [DriveApi.driveMetadataReadonlyScope];

  final tokenJson = io.File('token.json');

  if (tokenJson.existsSync()) {
    final fileContents = tokenJson.readAsStringSync();

    final contents = jsonDecode(fileContents);

    final expiry = DateTime.parse(contents['accessToken']['expiry']);
    final String type = contents['accessToken']['type'];
    final String data = contents['accessToken']['data'];
    final String? refreshToken = contents['refreshToken'];

    print(type);
    print(data);
    print(refreshToken);
    final accessToken = AccessToken(type, data, expiry);

    if (!accessToken.hasExpired) {
      final accessCredentials = AccessCredentials(accessToken, refreshToken, scopes);

      final headers = {"Authorization": "Bearer ${accessToken.data}"};

      httpClient = AuthenticateClient(headers, http.Client());
    }
  }

  if (httpClient == null) {
    httpClient = await clientViaUserConsent(
      ClientId(file['web']['client_id'], file['web']['client_secret']),
      [DriveApi.driveScope],
      (url) async {
        print(url);
      },
    );
  }

  if (httpClient is AutoRefreshingAuthClient) {
    final String? credentials = jsonEncode((httpClient as AutoRefreshingAuthClient).credentials);

    if (credentials != null) {
      await io.File('token.json').writeAsString(credentials);

      print(credentials);
    }
  }

  // final AccessCredentials creds = jsonDecode(credentials);

  // print(creds.runtimeType.toString());

  // final credentials = {
  //   "access_token": {"type": httpClient.credentials.accessToken.type, "data": httpClient.credentials},
  //   "": httpClient
  // };

  // print(httpClient.credentials.accessToken);

  // clientViaUserConsent(clientId, scopes, userPrompt)
  // final httpClient = await clientViaApplicationDefaultCredentials(scopes: [
  //   DriveApi.driveMetadataReadonlyScope,
  // ]);

  print('Authenticated');

  return httpClient;
}

listRootFiles(http.Client httpClient) async {
  print('Listing root files');
  final driveApi = DriveApi(httpClient);
  final String rootId = "root";
  final root = (await driveApi.files.get(rootId)) as File;

  print(root.name);
  print(root.id);
  print(root.driveId);
  print(root.mimeType);
  print(root.toJson());

  // final String parentId = "1n0zigH7O7NRb6VY6TBaSJKBeJFQELhmQ";
  // final String? parentId = root.id;

  final children = await listFiles(driveApi, root);

  final filesList = [];

  for (final child in children) {
    print(child.name);
    // print(child.mimeType);
    // print(child.fileExtension);
    await changeOwnershipRecursively(driveApi, child, moveToNewOwnersRoot: rootId == 'root');
    final owners = child.owners;

    if (owners != null) {
      for (final owner in owners) {
        // print("Owner: " + owner.displayName.toString());
      }
    }
    // print(child.name.toString() + ' ' + child.owners.toString());
  }

  print('Root filed listed.');
}

Future<List<File>> listFiles(DriveApi driveApi, File file) async {
  print('List files from ${file.name} of type ${file.mimeType}');
  final List<File> fileList = [];
  if (file.mimeType == MimeType.FOLDER.value) {
    await Future.delayed(Duration(milliseconds: 100));
    FileList children = await driveApi.files.list(
      q: "parents in '${file.id}' and trashed = false",
      $fields: "files(id, name, mimeType, trashed, ownedByMe), nextPageToken",
      pageSize: 1000,
    );

    bool continueLoop = true;

    while (continueLoop) {
      if (children.files != null && children.files!.length > 0) {
        fileList.addAll(children.files!);
      }

      print('Children size: ${children.files!.length}');
      print('File list size: ${fileList.length}');
      // print('Children size: ${children.files?.map((e) => e.toJson())}');

      final pageToken = children.nextPageToken;

      print('Page token: $pageToken');

      if (pageToken != null) {
        await Future.delayed(Duration(milliseconds: 100));
        children = await driveApi.files.list(
          q: "parents in '${file.id}' and trashed = false",
          $fields: "*",
          pageSize: 1000,
          pageToken: pageToken,
        );
      } else {
        continueLoop = false;
      }
    }
  }

  print('Files listed');

  return fileList;
}

Future<void> changeOwnershipRecursively(
  DriveApi driveApi,
  File file, {
  bool moveToNewOwnersRoot = false,
}) async {
  if (file.ownedByMe == true) {
    print('Changing ownership recursively');
    final Permission permission = Permission();

    permission.role = "owner";
    permission.type = "user";
    permission.emailAddress = newEmail;
    try {
      print('Creating persmission');
      await Future.delayed(Duration(milliseconds: 100));
      await driveApi.permissions.create(
        permission,
        file.id!,
        transferOwnership: true,
        moveToNewOwnersRoot: moveToNewOwnersRoot,
      );
      print('Permission created');
    } catch (error) {
      print('Error to create permission');
      if (error is DetailedApiRequestError) {
        print('Error status: ${error.status}');
        print('Error message: ${error.message}');
        print('Error jsonResponse: ${error.jsonResponse}');
        if (error.errors != null) {
          for (var err in error.errors) {
            print(err.reason);
          }
        }
      }
      print(error);
    }
    print('Ownership changed');
  }

  final List<File> children = await listFiles(driveApi, file);

  for (File child in children) {
    await changeOwnershipRecursively(driveApi, child);
  }
}

class AuthenticateClient extends http.BaseClient {
  final Map<String, String> headers;

  final http.Client client;

  AuthenticateClient(this.headers, this.client);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return client.send(request..headers.addAll(headers));
  }
}

class MyFile {
  final String name;
  final String mimeType;
  final String extension;
  final owners;

  MyFile(this.name, this.mimeType, this.extension, this.owners);
}

class MimeType {
  static MimeType FOLDER = MimeType._("application/vnd.google-apps.folder");
  final String value;
  MimeType._(this.value);
}
