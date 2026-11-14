<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

class AdminController extends \Lib\Controller {
  # perform authentication prior to access any admin endpoint
  # NOTE: This is a CHEAP method of security and not recommended as
  #       "sufficient" to enable exposing things on the public internet.
  protected function before() {
    if (Config::LOCK_ADMIN == "true") {
      if (!isset($_SERVER['PHP_AUTH_USER']) ||
          ($_SERVER['PHP_AUTH_USER'] != Config::ADMIN_USER || $_SERVER['PHP_AUTH_PW'] != Config::ADMIN_PASS)) {
        header('WWW-Authenticate: Basic realm="raspberry-noaa-v2"');
        header('HTTP/1.0 401 Unauthorized');
        echo 'Auth required';
        exit;
      }
    }
  }

  public function passesAction($args) {
    $pass = $this->loadModel('Pass');
    $pass->getActiveList();
    $args = array_merge($args, array('pass' => $pass,
                                     'admin_action' => 'passes'));
    View::renderTemplate('Admin/passes.html', $args);
  }

  # TODO: This is not very DRY between this and the above function - do
  #       something about this in the future
  public function deletePassAction($args) {
    $lang = include(__DIR__ . '/../Lang/' . Config::LANG . '.php');
    $pass = $this->loadModel('Pass');

    # attempt to delete the user-specified pass
    $status_msg = 'Fail';
    if (array_key_exists('pass_start_id', $args) and $args['pass_start_id'] > 0) {
      $pass_start_id = $args['pass_start_id'];
      $pass->getATJobId($pass_start_id);

      # attempt to remove the job ID
      try {
        echo shell_exec("sudo -u pi /usr/bin/atrm " . $pass->at_job_id . " 2>&1");
      } catch (exception $e) {
        error_log("Could not delete pass job ID using atrm for job ID: " . $pass->at_job_id . " - " . $e);
      }

      # attempt to delete the database record
      try {
        $pass->deleteByPassStart($pass_start_id);
      } catch (exception $e) {
        error_log("Could not delete pass from database for pass ID: " . $pass_start_id . " - " . $e);
      }

      $status_msg = 'Success';
    } else {
      $status_msg = $lang['fail_delete_missing_id'];
    }

    $pass->getActiveList();
    $args = array_merge($args, array('pass' => $pass,
                                     'status_msg' => $status_msg,
                                     'admin_action' => 'passes'));
    View::renderTemplate('Admin/passes.html', $args);
  }

  public function capturesAction($args) {
    $capture = $this->loadModel('Capture');
    $total_pages = $capture->totalPages(Config::ADMIN_CAPTURES_PER_PAGE);

    # pagination - and check for sanity
    $page_number = 1;
    if (array_key_exists('page_no', $args) and $args['page_no'] > 0) $page_number = $args['page_no'];
    if ($page_number > $total_pages) $page_number = $total_pages;

    $capture->getList($page_number, Config::ADMIN_CAPTURES_PER_PAGE);
    $args = array_merge($args, array('capture' => $capture,
                                     'cur_page' => $page_number,
                                     'page_count' => $total_pages,
                                     'admin_action' => 'captures'));

    View::renderTemplate('Admin/captures.html', $args);
  }

  # TODO: This is not very DRY between this and the above function - do
  #       something about this in the future
  public function deleteCaptureAction($args) {
    $lang = include(__DIR__ . '/../Lang/' . Config::LANG . '.php');
    $capture = $this->loadModel('Capture');
    $pass = $this->loadModel('Pass');

    $status_msg = 'Fail';

    if (array_key_exists('id', $args) and $args['id'] > 0) {
      $capture_id = (int)$args['id'];
      $details = $capture->getCaptureDetails($capture_id);

      if ($details !== null && (int)$details['sat_type'] === 2) {
        $capture_name = $details['file_path'];

        # ELEKTRO: only delete the two directories belonging to this capture.
        if (
          is_string($capture_name) &&
          preg_match('/^ELEKTRO-L3-\d{8}-\d{6}$/', $capture_name) &&
          $this->removeElektroCaptureDirectory(Config::THUMB_PATH, $capture_name) &&
          $this->removeElektroCaptureDirectory(Config::IMAGE_PATH, $capture_name)
        ) {
          $capture->deleteById($capture_id);
          $status_msg = 'Success';
        }
      } elseif ($details !== null) {
        # Preserve the existing deletion behaviour for non-ELEKTRO captures.
        $capture->getEnhancements($capture_id);
        $capture->getImagePath($capture_id);

        foreach ($capture->enhancements as $enhancement) {
          $img = Config::IMAGE_PATH . '/' . $capture->image_path . $enhancement;
          $thumb = Config::THUMB_PATH . '/' . $capture->image_path . $enhancement;

          try {
            if (file_exists($img)) { unlink($img); }
          } catch (exception $e) {
            error_log("Could not delete file: " . $img . " - " . $e);
          }

          try {
            if (file_exists($thumb)) { unlink($thumb); }
          } catch (exception $e) {
            error_log("Could not delete file: " . $thumb . " - " . $e);
          }
        }

        $capture->getStartEpoch($capture_id);
        $capture->deleteById($capture_id);
        $pass->deleteByPassStart($capture->start_epoch);
        $status_msg = 'Success';
      }
    } else {
      $status_msg = $lang['fail_delete_missing_id'];
    }

    $total_pages = $capture->totalPages(Config::ADMIN_CAPTURES_PER_PAGE);

    # pagination - and check for sanity
    $page_number = 1;
    if (array_key_exists('page_no', $args) and $args['page_no'] > 0) $page_number = $args['page_no'];
    if ($page_number > $total_pages) $page_number = $total_pages;

    $capture->getList($page_number, Config::ADMIN_CAPTURES_PER_PAGE);
    $args = array_merge($args, array('capture' => $capture,
                                     'cur_page' => $page_number,
                                     'page_count' => $total_pages,
                                     'status_msg' => $status_msg,
                                     'admin_action' => 'captures'));

    View::renderTemplate('Admin/captures.html', $args);
  }

  # Safely remove one ELEKTRO capture directory without following symlinks.
  private function removeElektroCaptureDirectory($basePath, $captureName) {
    if (!preg_match('/^ELEKTRO-L3-\d{8}-\d{6}$/', $captureName)) {
      return false;
    }

    $baseReal = realpath($basePath);
    if ($baseReal === false || !is_dir($baseReal)) {
      error_log("ELEKTRO deletion: invalid base directory: " . $basePath);
      return false;
    }

    $candidate = $baseReal . DIRECTORY_SEPARATOR . $captureName;

    if (is_link($candidate)) {
      error_log("ELEKTRO deletion refused symbolic link: " . $candidate);
      return false;
    }

    # A missing directory is already in the desired state.
    if (!file_exists($candidate)) {
      return true;
    }

    $targetReal = realpath($candidate);

    if (
      $targetReal === false ||
      !is_dir($targetReal) ||
      dirname($targetReal) !== $baseReal
    ) {
      error_log("ELEKTRO deletion refused unsafe path: " . $candidate);
      return false;
    }

    try {
      $iterator = new \RecursiveIteratorIterator(
        new \RecursiveDirectoryIterator(
          $targetReal,
          \FilesystemIterator::SKIP_DOTS
        ),
        \RecursiveIteratorIterator::CHILD_FIRST
      );

      foreach ($iterator as $item) {
        $path = $item->getPathname();

        # Symlinks are unlinked, never traversed.
        if ($item->isLink() || !$item->isDir()) {
          if (!@unlink($path)) {
            error_log("ELEKTRO deletion failed to unlink: " . $path);
            return false;
          }
        } else {
          if (!@rmdir($path)) {
            error_log("ELEKTRO deletion failed to remove directory: " . $path);
            return false;
          }
        }
      }

      if (!@rmdir($targetReal)) {
        error_log("ELEKTRO deletion failed to remove capture root: " . $targetReal);
        return false;
      }

      return true;
    } catch (\Throwable $e) {
      error_log("ELEKTRO deletion exception: " . $e->getMessage());
      return false;
    }
  }

}


?>
