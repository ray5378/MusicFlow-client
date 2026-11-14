// 学习歌单文件夹「进入文件夹」语义的路径工具回归守卫：
//   * 逐级补全父目录（只有子目录、没有直属歌单的父目录也要能显示）；
//   * 自然序（1 < 3 < 10，而不是字典序）；
//   * 根层 / 直接子层划分（父层不能把孙目录也列出来，否则又变成「摊平」）；
//   * 标题取最后一段。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/features/study/study_folder_tree.dart';

void main() {
  test('逐级补全父目录并按自然序排列', () {
    expect(
      buildStudyFolderPaths(<String>['课程/10', '课程/3']),
      <String>['课程', '课程/3', '课程/10'],
      reason: '父目录「课程」没有直属歌单时也要出现；数字按数值排序',
    );
  });

  test('空白段、空串、重复路径都被清理', () {
    expect(
      buildStudyFolderPaths(<String>['  课程 ', '课程', '', '  ', '课程//3']),
      <String>['课程', '课程/3'],
    );
  });

  test('根层只返回不含斜杠的路径', () {
    final all = buildStudyFolderPaths(<String>['课程/高数', '英语']);
    expect(rootStudyFolders(all), <String>['英语', '课程']);
  });

  test('直接子文件夹只取一层，不含孙子目录', () {
    final all = buildStudyFolderPaths(<String>['课程/高数/第一章', '课程/高数', '课程/英语']);
    expect(studyChildFolders(all, '课程'), <String>['课程/英语', '课程/高数']);
    expect(studyChildFolders(all, '课程/高数'), <String>['课程/高数/第一章']);
  });

  test('父路径为空串等价于根层', () {
    final all = buildStudyFolderPaths(<String>['课程/高数', '英语']);
    expect(studyChildFolders(all, ''), rootStudyFolders(all));
  });

  test('标题取路径最后一段', () {
    expect(studyFolderLabel('课程/高数'), '高数');
    expect(studyFolderLabel('英语'), '英语');
  });
}
